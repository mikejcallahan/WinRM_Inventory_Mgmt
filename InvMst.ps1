
[string]$currentPSuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name;
[string]$currentPSUserNotFQ = [string](($currentPSuser -split '\\')[-1]);
[string]$version = "1.3.0";
[string[]]$erlog = @();
[string]$invRmtLog = ".\InvRmt.log"

  write-host ("
  ***********************************************************************************************************
  Inventory Management Master $($version) | Pleroma Tech LLC | Mike J Callahan 2023 | MIT license 

  Requires WinRM service and firewall exception on target machines. Invokes commands on PCs listed in PCList.txt file. Estimates primary user 
  with temp folder if no Explorer.exe owner exists - otherwise this is given priority. Estimated user, PC name and serialnumber are included in 
  filename of CSV reports. PSuser($currentPSuser), username in passed credentials, system and default user profiles, and users in ignore txt file are 
  skipped/ignored. If no user can be estimated 'UNKNOWN' is used. 
  *list files will be created(If missing) after initializing and will give instructions for using. PC list requires at least 1 target PC.

  COMMANDS: get-package -Provider Programs -includewindowsinstaller

  ***********************************************************************************************************
  USAGE: type 'initialize_inventory -start' <ENTER>

  INTERACTIVE:           -start
  CONSOLE LOOP:          -utility -loop

  OPTIONAL SWITCHES:
  USER:                  -runAsUser <username(fully qualified)>
  EDIT PCLIST:           -pclistedit
  DEVELOPER INFO:        -dev
  ************************************************************************************************************
  ")

function Initialize_Inventory([switch]$start,[string]$domain="IT",[string]$runAsUser=$currentPSuser,[int]$cadence=60,[switch]$utility,[switch]$loop=$true,[switch]$dev,[switch]$pclistedit) {                                <# SECONDS FOR LOOP TO PAUSE #>
  
  
  [string]$rptServer=             "$($env:COMPUTERNAME)";            <# THIS APP MUST RESIDE ON THIS SERVER NO NETWORK LOCATION YET#>
  [string]$rptStore =             $dirParent;                        <#GETS CONVERTED TO REMOTE PATH LATER.NEEDS TO BE LOCAL NON UNC PATH. IN ORDER TO ISOLATE RUNAS AND SESSION USER VARS #> 
  [string]$rptStorePCDir =        "$($rptStore)\PC";
  [string]$userIgnore =           ".\UserIgnore.txt";                <# FOR UTILITY ACCOUNTS AND ANY USERS YOU WANT TO IGNORE ON PCS #>
  [string]$defaultPCList =        ".\PCList.txt";
  [string]$pingEnginePath =       ".\util\pcping5.exe";              <# MULTI-THREAD PING. THIS IS SEPARATE CONSOLE APP THAT TAKES STRING[] OF PC NAMES AND RETURNS NOT-ONLINE LIST. REG PING USED IF MISSING #>
  [int]$peThresh =                4;                                 <# HOW MANY PCS BEFORE CHANGING TO MULTI-THREAD PING. #>
  [string]$scriptname =           split-path -Leaf $MyInvocation.MyCommand.Definition;
  
  [string]$stage =                "c:\users\public\$($domain)\INV";
  $creds =                        $false;
  if($dev){ write-host ("
  Future improv:
    HTML front-end. Will be using python for generating most page content we think.
    pull out credential process to front-end. Initialize_inventory to be compiled and run as a service.
    Additional functions to be pulled out. switch added for updating command list. This is what will be run
  ")}
  function Log([string]$msg){$global:erlog += $msg; if($dev){write-host "$($msg)" }}
  <#------------------------------------------------------------------------------------------------
  GETCREDS: calls internal getUser > getPass > makes and returns credential
  -------------------------------------------------------------------------------------------------#>
 <# function getCreds([string]$runAsUser) {
    function getUser{ try{ [string]$u = read-host "Run As User"; return $u;
                      }catch{ log -msg "GC:GU:$($error[0])"; return "False";}}
    function getPass{ try{ $pw=read-host "password(encrypted)" -AsSecureString; return $pw;
                      }catch{ log -msg "GC:GP:$($error[0])"; return "False";}}
    try{
      write-host "CREDENTIALS";
      if($null -eq $runAsUser){$runAsUser = getUser} if($runAsUser -eq "False") { return $false }
      $pw = getPass; if($pw -eq "False") {return $false}
      $creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $runAsUser, $pw;
      return $creds;
    }catch{ log -msg "GC:$($error[0])"; return $false }
    write-host "NO CREDENTIAL RETURNED"
    }#>
  <#-------------------------------------------------------------------------------------------------
  Inventory1: Runs getPrograms and estimates user of PC. 
  --------------------------------------------------------------------------------------------------#>
  function inventory1 ($creds,[string[]]$pclist, [string]$injectInfo, [switch]$cacheReset) { if($injectInfo -eq $null){$injectInfo="STARTED $(get-date -Format 'yyyy-MM-dd-hh:mm')"}
      write-host ("
      $injectInfo
      ***********************************************************************************************************") 
      <#-------------------------------------------------------------------------------------------
      HOUSEKEEPING: Calls getCreds
      --------------------------------------------------------------------------------------------#>
      
     <# function housekeeping {
        try{ if ($null -eq $creds) { $creds =  get-credential} #getCreds -runAsUser $runAsUser; $creds = $creds} 
        }catch{ log -msg "Inv1:HK:$($error[0])";write-host "CREDENTIAL FAILED $($error[0])"; return $false }
        if(!($null -eq $creds)){ $creds=$creds; return "True" }else{ return $false }
      }
      if(!(housekeeping )) { return "False" }#>
      <#
      if(($null -eq $rptStore) -or 
      (($rptStore).toupper()).contains("$env:COMPUTERNAME")) -or
      #>
      <#--------------------------------------------------------------------------------------------
      IGNORE  LIST GET USERS.
      --------------------------------------------------------------------------------------------#>
      if(test-path -path "$($userIgnore)") {[string[]]$forboden = @(get-content -Path "$($userIgnore)"); $forboden += "$($creds.username)",$currentPSUserNotFQ,$currentPSuser,"PUBLIC","ADMINISTRATOR","DEFAULT"
        for($v=0;$v-lt($forboden.count);$v++) { $forboden[$v] = $forboden[$v].toupper() }
      }else{ new-item -Path "$($userIgnore)" -ItemType file | out-null; start-process explorer -erroraction SilentlyContinue -args "$($userIgnore)"; 
        return "ADD TO IGNORE LIST USERNAMES TO IGNORE WHEN INVOKED ON TARGET PC. NO QUOTES OR COMMAS - 1 PER LINE ('`$env:COMPUTERNAME', 'ADMINISTRATOR', 'PUBLIC' & 'DEFAULT' DIRS WILL BE SKIPPED AUTOMATICALLY)" }
      WRITE-HOST "IGNORELIST:$forboden"
      #foreach($f in $forboden) {write-host ("      $f")} # Import-Module -Name $myModuleFilePath -Verbose. You can add -NoClobber 
      <#---------------------------------------------------------------------------------------------------------------
      GET ONLY ACTIVE CONNECTIONS
      --------------------------------------------------------------------------------------------------------------#>
      write-host "SEPARATING DISCONNECTED PCs"
      $PCNotConnected = @();$activePCList = @()
      function regularPing($list){ $PCnot=@(); write-host "[RUNNING REGULAR PING]";foreach($pc in $list){ try{ Test-connection -computername $pc -count 1 -erroraction stop | out-null } catch {$PCnot += $pc} continue }
        return $PCnot
      }
      try {  if($pclist.count -gt $peThresh){$PCNotConnected = @(& $pingEnginePath $pclist) }else{$PCNotConnected=regularPing -list $pclist;} 
      }catch{ write-host "$($error[0])"; $PCNotConnected=regularPing -list $pclist;
      }
      for($i=0;$i-lt$pclist.count;$i++){ if(!($PCNotConnected -contains $pclist[$i])) { $activePCList += $pclist[$i] }}
      if($dev){ write-host "NOT ACCESSIBLE: `r`n ------------------"; foreach($pc in $PCNotConnected) {write-host "$PC"}}
      write-host "CONNECTED: $($activePCList.count) OUT OF $($pclist.count)";

      if ($null -ne $creds) {                                                                        
		write-host "RUNNING COMMANDS"																	
       <#*****************************************************************************************************
       BELOW IS INVOKED ON REMOTE MACHINES
       -----------------------------------------------------------------------------------------------------#>
        try { 																						
          invoke-command -computername $activePCList -Credential $creds -Errorvariable erInv1 -ScriptBlock  {  
            [string]$cacheReset = $using:cacheReset
            [string]$rptStore = $using:rptServerStore
            [string]$stage= $using:stage
            [string]$rptServer = $using:rptServer
            [string]$rptStorePCDir = $using:rptServerPCDir
            [string[]]$forboden = $using:forboden
            [string]$domain = $using:domain
            [string]$currentPSuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name   
            [switch]$dev = $using:dev
            <#---------------------------------------------------------------------------------------------
            CACHE FOLDER 
            ------------------------------------------------------------------------------------------------#>
            $makefolder = (test-path -path $stage)
            if(!($makefolder)) { New-Item -ItemType "directory" -Path $stage | out-null }
            if($cacheReset) { remove-item "$stage\*.csv*" }
            set-location -path $stage

            <#---------------------------------------------------------------------------------------------
            USER APPROX 1st; EXPLORER OWNER: CHEAP WAY TO APPROXIMATE THE ASSIGNEE OF A PC. WORKS IF THEY ARE LOGGED IN
            ------------------------------------------------------------------------------------------------#>
            function getUserByExplorer {
              [string]$userEstExplorerOwner = (Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" |
              ForEach-Object { $_.GetOwner() } | Select-Object -Unique -Expand User) 
              return $userEstExplorerOwner
            }
            <#----------------------------------------------------------------------------------------------
            USER APPROX 2nd; TEMP FOLDER: EXPENSIVE 
            -----------------------------------------------------------------------------------------------#>
            function getUserByTempFolder([switch]$raw,[string[]]$ignorelist,[string]$domain) {<# WILL SELECT WHOEVER RUNS THIS SCRIPT IF INVOKED. SO THAT USER IS ADDED TO IGNORE LIST
            .DESCRIPTION 
            Get users from c:\users. Get mod time of each temp folder. Sort descending. concat username and sorted time together using common indices (creates a ref of the correct order of users | separate parallel arrays = alt to hashtables,objects or jagged arrays)
            reorder names into desc order excluding system and admin users.raw switch will return all users sorted. Without switch you get the top result excluding admins (most likely assignee of the PC)
            .OUTPUTS <string[]>
            #>
              [string[]]$forboden = $ignorelist;  $forboden += (([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).replace("$($domain)\",''));  <# ADDING CURRENT USER TO IGNORE LIST #>
              try{ $userfolders = @(Get-childitem "c:\users\" -Directory | Sort-Object -Property {$_.LastWriteTime} -Descending) 
                [string[]]$ulist = @(); [string[]]$uTimes = @(); [string[]]$uListValid = @(); [string[]]$uListPrep = @()
                For($i=0;$i-lt$userfolders.count;$i++) { [string]$n = $userfolders[$i] | select Name; [string]$nn = ($n.replace("@{Name=","")).replace("}",""); $ulist += $nn }
                forEach($u in $ulist){ if(Test-path -Path "c:\users\$($u)\appdata\local\temp") { 
                try{ [string]$temp = (Get-Item -Path "c:\users\$($u)\appdata\local\temp" -erroraction stop | select { $_.LastWriteTime.toString("yyyyMMddhhmm")})
                $t = ($temp.replace('@{ $_.LastWriteTime.toString("yyyyMMddhhmm")=',"")).replace("}","")
                $uTimes += $t; $uListPrep += $u
                }catch{ continue }}}
                $temparr = @($null) * $uListPrep.count; $tempArr2 = @($null) * $uListPrep.count                                                  
                for($i=0;$i-lt$uTimes.count;$i++) { $tempArr[$i] = "$($uTimes[$i])" + "$($uListPrep[$i])" }   
                $uTSorted = $uTimes | sort-object -Descending                                                 
                for($z=0;$z-lt$uTimes.Count;$z++) { for($i=0;$i-lt$uTimes.count;$i++) { if($temparr[$i].contains($uTSorted[$z])) { $tempArr2[$z] = ($tempArr[$i]).replace("$($uTSorted[$z])","") # where the magic happens
                }}}
                [string[]]$tempArr3 = @()
                if(!$raw) { foreach($a in $tempArr2) { if((!($forboden -contains $a.toupper())) -and (!((($a.toUpper())).contains(($env:computername).toupper())))) { $tempArr3 += $a }}
                return $tempArr3[0] }else{ return $tempArr2}
              }catch { write-host "$($error[0])"; return $null }
            }
            <#--------------------------------------------------------------------------------------------------------------------
            USER APPROX 3; PROFILE FOLDER DEPTH(NOT SIZE): LOBSTER PLATE WITH FOOT MASSAGE- OVERKILL. GOES LONG AND PS LIMITS RECURSION 
            TO <100 CALLS WHICH THREW A WRENCH IN THE WHOLE THING. HAVE TO REWRITE. ABANDONED FOR NOW: LEFT OFF: ..\scripts2024\getUserByFolderSize.ps1
            ----------------------------------------------------------------------------------------------------------------------#>
            <#$objUDirs = @(get-ChildItem C:\users -ErrorAction SilentlyContinue)
            [string[]]$udirs = @(get-ChildItem $objUDirs -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
            [int[]]$intSizes,$intSzTmp = @() * ($udirs.count); 
            for($y=0;$y-lt($udirs.count);$y++) {[int]$Sz = Get-ChildItem ($objUserdir[$y].FullName) -erroraction silentlycontinue -recurse | Measure-Object -property length -sum | Select-Object -ExpandProperty Count
            $intSizes += $Sz; 
            }
            for($x=0;$x-lt($udirs.Count);$x++) { 
             for($z=0;$z-lt($uDirs.count);$z++) { 
               if($z -eq (($intSizes.count) - 1)) {                                                             # END OF RANGE CASE
                 if($intSizes[$z] -gt $intSzTmp[$x]) { $intSzTmp[$x] = $intSizes[$z];}
               }elseif($intSizes[$z] -gt $intSizes[$z+1]) { $intSzTmp[$z] = $intSizes[$z+1]; $intSzTmp[$z+1] = $intSizes[$z] 
            } } }  #>                  #LEFT OFF HERE 04/5
            #[pscustomobject]$userFolderSize = @(Get-ChildItem $objUDirs -erroraction silentlycontinue -recurse | Measure-Object -property Length -sum)
            #[int[]]$intUserFolderSize = @(Select-Object -ExpandProperty Count)
            <#-------------------------------------------------------------------------------------------------------
            USER ESTIMATION WEIGHTS/LOGIC
            -------------------------------------------------------------------------------------------------------------#> 
            [string]$passedUserEstimate = ""
            [string]$userEstTempFolder = getUserByTempFolder -ignoreList $forboden -domain $domain
            [string]$userEstExplorerOwner = getUserByExplorer
            if(($userEstExplorerOwner -ne "") -and (!($forboden -contains $userEstExplorerOwner))) { $passedUserEstimate = $userEstExplorerOwner
            }elseif($userEstTempFolder -ne ""){ $passedUserEstimate = $userEstTempFolder
            }else{ $passedUserEstimate = "UNKNOWN" }
            <#---------------------------------------------------------------------------------------------
            GET PROGRAMS EXPORT CSV (this now works in non-admin user run batch file) this will get pulled out into separate batch file run by user. The command runs as non-admin
            ------------------------------------------------------------------------------------------------#>
            get-package -Provider Programs -includewindowsinstaller| Select "Name", "Version", "Summary", "CanonicalId", "InstallLocation", "InstallDate", "UninstallString", "QuietUninstallString", "ProductGUID"  | 
            export-csv ("$($stage)\" + (hostname) + "(" + ((& {wmic bios get serialnumber;}) -join "" -replace("SerialNumber","") -replace(" ","")) + ")_$(($passedUserEstimate).toUpper())_" + "-_Apps_-" + ".csv") -notypeinformation -force
     
            <#---------------------------------------------------------------------------------------------
            EVENT LOGS
            -----------------------------------------------------------------------------------------------#>
            if($dev) { write-host "PC:$($env:computername)|PS:$($currentPSUser)|TU:$($userEstTempFolder)|EO:$($userEstExplorerOwner)|PU: $($passedUserEstimate)"}
          }      
          <#-------------------------------------------------------------------------------------------------------------------------
          END INVOKE ARGS
          -------------------------------------------------------------------------------------------------------------------------- #>
        }catch{   log -msg "Inv1:Main:$($error[0])"}
      }else{    write-host "CREDENTIAL FAILED";break;
      }try{     if(!(test-path -path $invRmtLog)){new-item -ItemType file -Path $invRmtLog} $erInv1 | out-file -FilePath $invRmtLog -append; write-host "THERE WERE ERRORS. CHECK LOG"}catch{ log -msg "Inv1:PSrm: $($error[0])"}
     <#-------------------------------------------------------------------------------------------------------------------------
     COPY FILES FROM PCs TO LOG LOCATION
     -------------------------------------------------------------------------------------------------------------------------- #>
    write-host "COPYING LOGS TO $rptServer";

    [string]$stageRemote = $stage.replace(':','$');
    [string]$rptStorePCDirRemote = "$($rptStorePCDir.replace(':','$'))";             # SMB path is used for case where script is run on diff server than rptServer
    foreach($pc in $activePCList) { 
      [string]$copyLogCommand = "& robocopy `"\\$pc\$stageRemote`" `"\\$($rptServer)\$($rptStorePCDirRemote)`" `"*$($pc.toupper())*`" /r:0 /w:0 "
      if(($dev) -and ($activePCList[0] -eq $pc)) { write-host "ROBOCOPY ARG USED: $copyLogCommand" }
      invoke-expression $copyLogCommand | out-null; 
    }return $true;
  }

 <#-------------------------------------------------------------------------------------------------------
 PCListCheck
 .DESCRIPTION 
 CHECKS DefaultPCList PATH. MAKES FILE IF NOT PRESENT
 .OUTPUTS 
 <string[]>
 ----------------------------------------------------------------------------------------------------------#>
  function PCListCheck([string]$defaultPCList) {       
    set-location -path $PSScriptRoot                       
    if (!(test-path -Path $defaultPCList)) { try { New-Item -ItemType file -path $defaultPCList }catch [exception] { write-host "$($error[0])"; break }
    }else{ [string[]]$PCList = @(get-content -path $defaultPCList); if(!($PCList.count -gt 0)){write-host "ADD PCs TO PCLIST AND RERUN"; break }else{ return $PCList}}
  }

 <#-------------------------------------------------------------------------------------------------------
 PCListEdit
 .DESCRIPTION 
 INTERACTIVE. CHECKS DefaultPCList PATH. MAKES FILE IF NOT PRESENT
 .OUTPUTS 
 <string[]>
 ----------------------------------------------------------------------------------------------------------#>
 function PCListEdit {                                              #INTERACTIVE FUNCTION
    set-location -path $PSScriptRoot                                # prep for relative path
    if (!(test-path -Path $defaultPCList)) { try { New-Item -ItemType file -path $defaultPCList }catch [exception] { write-host "$($error[0])";
      break;                                                         # abort on failure
    }}
    write-host "[EDIT TARGET LIST] $defaultPCList" ; start-process notepad.exe -wait -ArgumentList $defaultPCList;    # open pc list file 
    [string[]]$PCList = @(get-content -path $defaultPCList)                 

    if($PCList.count -lt 1){ write-host "[ADD AT LEAST 1 TARGET PC NAME]"; PCListEdit }                         
    return $PCList                                                  # returns names array to caller
  }
  <#------------------------------------------------------------------------------------
  getCreds
  -------------------------------------------------------------------------------------#>
   function getCreds {[string]$m="ADMIN TO AUTHENTICATE ON REMOTE MACHINES.(FQDN)"; try{ $creds=get-credential -user $runAsUser -Message $m; return $creds; if($null -eq $creds){ return }}catch{log -msg "GC:$($error[0])";return $false}}
  <#---------------------------------------------------------------------------------------------
  UtilityLoop - NON-INTERACTIVE
  ----------------------------------------------------------------------------------------------#>
  function UtilityLoop($creds,[int]$run,[string]$info,[string]$startTime,[boolean]$state) {
  if($state -eq $false) { $global:erlog += "[UL:Run:$($run):$($error[0])"; return $false }
  if(!($run -eq 0)){write-host "WAITING $cadence SECONDS"; start-sleep -Seconds $cadence}
  if($null -eq $creds) { $creds = getCreds }
  $LoopTimer = [Diagnostics.Stopwatch]::StartNew();
  if($null -eq $run) { $run = 0 }
  if(($null -eq $startTime) -or ($run -eq 0)) { [string]$startTime = "$(Get-Date -format ('yyyy/MM/dd hh:mm'))" }
  [string[]]$pclist = PCListCheck -defaultPCList $defaultPCList;
  $state = inventory1 -creds $creds -pclist $pclist -injectInfo $info -cacheReset; 
  if(!($state)){return $false}
  $run = $run + 1;
  [string]$info = "[TIMINGS] RUN:$($run) |LASTRUN(SECONDS):$($LoopTimer.elapsed.totalseconds) | STARTED: $($startTime)";
  $LoopTimer.stop()
  UtilityLoop -creds $creds -run $run -info $info -startTime $startTime -state $state;
  }
  <#----------------------------------------------------------------------------------------------------------------------
  Interactive
  -----------------------------------------------------------------------------------------------------------------------#>
  function Interactive { [string[]]$pclist = PCListEdit;    #getCreds -runAsUser $runAsUser;
  $creds=getCreds; read-host "PRESS ENTER TO START"; $startTime = "$(Get-Date -format ('yyyy/MM/dd hh:mm'))";
  $state=(inventory1 -pclist $pclist -creds $creds -cacheReset); if($state -eq $false){ return $false }else{ UtilityLoop -run 1 -info "CONTINUING QUERIES IN LOOP" -startTime $startTime -state $true }
  }

  
  <#---------------------------------------------------------------------------------------------------
  INITIALIZE ARGS 
  ----------------------------------------------------------------------------------------------------#>
  
  if($start -and (!($utility))) { Interactive }elseif($utility -and (!($loop))) { Inventory1 }
  elseif($utility -and $loop) { UtilityLoop -state $true }elseif($pclistedit) { PCListEdit; write-host "PCLIST EDITED. RERUN TO USE"}
  if($erlog.count > 0) { $erlog | out-file $invRmtLog -Append; write-host "Errors encountered. See $($invRmtLog)" }
  }

  