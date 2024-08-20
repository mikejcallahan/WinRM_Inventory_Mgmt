param([switch]$help=$true)

function help {
  function info{
    write-host ("
    ***********************************************************************************************************
    Inventory Management Master 1.3.0 | Pleroma Tech LLC | Mike J Callahan 2023 | MIT license 

    Requires WinRM service and firewall exception on target machines. Invokes commands on PCs listed in PCList.txt file. Estimates primary user 
    with temp folder if no Explorer.exe owner exists - otherwise this is given priority. Estimated user, PC name and serialnumber are included in 
    filename of CSV reports. PS Session owner, username in passed credentials, system and local Administrator user profiles, and users in ignore txt file are 
    skipped/ignored. If no user can be estimated 'UNKNOWN' is used. 
    *list files will be created(If missing) after initializing and will give instructions for using. PC list requires at least 1 target PC.

    ***********************************************************************************************************
    COMMANDS: get-package -Provider Programs -includewindowsinstaller
    
    USAGE: 'initialize_inventory -start' <ENTER>
    INTERACTIVE:           -start
    CONSOLE LOOP:          -utility -loop

    OPTIONAL SWITCHES:
    RUN AS USER:           -runAsUser <username(fully qualified)>
    EDIT PCLIST:           -pclistedit
    DEVELOPER INFO:        -dev
    ************************************************************************************************************
    ")
  }
  info; break;
}
  

function Initialize_Inventory([switch]$start,[string]$domain="IT",[string]$runAsUser=$currentPSuser,[int]$cadence=60,[switch]$utility,[switch]$loop=$true,[switch]$dev,[switch]$pclistedit,[string]$pth) { 
  if($dev){ write-host ("
    Future improv: HTML front-end. Will be using python for generating most page content we think; pull out credential process to front-end. Initialize_inventory to be compiled and run as a service.
    Additional functions to be pulled out. switch added for updating command list. Therefore these can be loaded in perpetuity once the app is compiled.
  ")}
  [int]$id=                       -1; <# function code #>
  [string]$currentPSuser =        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name;
  [string]$currentPSUserNotFQ =   [string](($currentPSuser -split '\\')[-1]);
  #[string]$scriptname =           split-path -Leaf $MyInvocation.MyCommand.Definition;
  [string]$dirParent =            $PSScriptRoot;
  [string]$rptServer=             "$($env:COMPUTERNAME)";            <# THIS APP MUST BE LOCALLY RUN ON THIS SERVER  #>
  [string]$rptStore =             $dirParent;                        <# GETS CONVERTED TO REMOTE PATH LATER. #> 
  [string]$rptStorePCDir =        "$($rptStore)\PC";
  [string]$userIgnore =           ".\UserIgnore.txt";                <# FOR UTILITY ACCOUNTS AND ANY USERS YOU WANT TO IGNORE ON PCS LIKE ADMINS#>
  [string]$defaultPCList =        ".\PCList.txt";
  [string]$pingEnginePath =       ".\util\pcping5.exe";              <# MULTI-THREAD PING. THIS IS SEPARATE CONSOLE APP THAT TAKES STRING[] OF PC NAMES AND RETURNS NOT-ONLINE LIST. REG PING USED IF MISSING #>
  [int]$peThresh =                4;                                 <# HOW MANY PCS BEFORE CHANGING TO MULTI-THREAD PING. #>
  
  [string]$stage =                "c:\users\public\$($domain)\INV";                        <# WHERE FILES ARE STAGED ON REMOTE SYSTEM #>
  [PSObject]$creds =              $false;
  [string]$logFile =              ".\InvMst.log";
           
  <#-------------------------------------------------------------------------------------------------
  Inventory1: Runs getPrograms and estimates user of PC. 
  --------------------------------------------------------------------------------------------------#>
  function inventory1 ([int[]]$fCodes,$creds,[string[]]$pclist, [string]$injectInfo, [switch]$cacheReset) { if($injectInfo -eq $null){$injectInfo="STARTED $(get-date -Format 'yyyy-MM-dd-hh:mm')"}
      #[int]$id=6;
	  write-host ("
      $injectInfo
      ***********************************************************************************************************") 
      
      <#--------------------------------------------------------------------------------------------
      IGNORE  LIST GET USERS.
      --------------------------------------------------------------------------------------------#>
      if(test-path -path "$($userIgnore)") {[string[]]$forboden = @(get-content -Path "$($userIgnore)"); $forboden += "$($creds.username)",$currentPSUserNotFQ,$currentPSuser,"PUBLIC","ADMINISTRATOR","DEFAULT"
        for($v=0;$v-lt($forboden.count);$v++) { $forboden[$v] = $forboden[$v].toupper() }
      }else{ new-item -Path "$($userIgnore)" -ItemType file | out-null; start-process explorer -erroraction SilentlyContinue -args "$($userIgnore)"; 
        return "ADD TO IGNORE LIST USERNAMES TO IGNORE WHEN INVOKED ON TARGET PC. NO QUOTES OR COMMAS - 1 PER LINE ('`$env:COMPUTERNAME', 'ADMINISTRATOR', 'PUBLIC' & 'DEFAULT' DIRS WILL BE SKIPPED AUTOMATICALLY)" }
      WRITE-HOST "IGNORELIST:$forboden"; 
      <#---------------------------------------------------------------------------------------------------------------
      GET ONLY ACTIVE CONNECTIONS
      --------------------------------------------------------------------------------------------------------------#>
      write-host "SEPARATING DISCONNECTED PCs"; $PCNotConnected = @();$activePCList = @()
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
          invoke-command -computername $activePCList -Credential $creds -ErrorAction SilentlyContinue -Errorvariable erRmt -ScriptBlock  {  
            [string]$cacheReset = $using:cacheReset
            [string]$rptStore = $using:rptStore
            [string]$stage= $using:stage
            [string]$rptServer = $using:rptServer
            [string]$rptStorePCDir = $using:rptStorePCDir
            [string[]]$forboden = $using:forboden
            [string]$domain = $using:domain
            [string]$currentPSuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name   
            [switch]$dev = $using:dev
            <#---------------------------------------------------------------------------------------------
            CACHE FOLDER 
            ------------------------------------------------------------------------------------------------#>
            $makefolder = (test-path -path $stage); if(!($makefolder)) { New-Item -ItemType "directory" -Path $stage | out-null }
            if($cacheReset) { remove-item "$stage\*.csv*" }
            set-location -path $stage;
            <#---------------------------------------------------------------------------------------------
            USER APPROX 1st; EXPLORER OWNER: CHEAP
            ------------------------------------------------------------------------------------------------#>
            function getUserByExplorer { [string]$userEstExplorerOwner = (Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" |
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
              try{ 
                $userfolders = @(Get-childitem "c:\users\" -Directory | Sort-Object -Property {$_.LastWriteTime} -Descending);
                [string[]]$ulist = @(); [string[]]$uTimes = @(); [string[]]$uListValid = @(); [string[]]$uListPrep = @();
                for($i=0;$i-lt$userfolders.count;$i++) { [string]$n = $userfolders[$i] | select Name; [string]$nn = ($n.replace("@{Name=","")).replace("}",""); $ulist += $nn }
                forEach($u in $ulist){ if(Test-path -Path "c:\users\$($u)\appdata\local\temp") { 
                try{ 
                  [string]$temp = (Get-Item -Path "c:\users\$($u)\appdata\local\temp" -erroraction stop | select { $_.LastWriteTime.toString("yyyyMMddhhmm")})
                  $t=($temp.replace('@{ $_.LastWriteTime.toString("yyyyMMddhhmm")=',"")).replace("}","")
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
        }catch{   $erlog+="$($myInvocation.MyCommand.Name):$($error[0])"}
      }else{    write-host "CREDENTIAL FAILED";return $false;
      } if($null -ne $erRmt){$erlog+=$erRmt}
     <#-------------------------------------------------------------------------------------------------------------------------
     COPY FILES FROM PCs TO LOG LOCATION
     -------------------------------------------------------------------------------------------------------------------------- #>
    write-host "COPYING LOGS TO $rptServer";

    [string]$stageRemote = $stage.replace(':','$');
    [string]$rptStorePCDirRemote = "$($rptStorePCDir.replace(':','$'))";             
    foreach($pc in $activePCList) { 
      [string]$copyLogCommand = "& robocopy `"\\$pc\$stageRemote`" `"\\$($rptServer)\$($rptStorePCDirRemote)`" `"*$($pc.toupper())*`" /r:0 /w:0 ";
      if(($dev) -and ($activePCList[0] -eq $pc)) { write-host "ROBOCOPY ARG USED: $copyLogCommand" }
      invoke-expression $copyLogCommand | out-null; 
    }return $true;
  }
  <#-------------------------------------------------------------------------------------------------------
  PCListCheck
  ----------------------------------------------------------------------------------------------------------#>
  function PCListCheck([string]$defaultPCList) {       
    set-location -path $PSScriptRoot                       
    if (!(test-path -Path $defaultPCList)) { try { New-Item -ItemType file -path $defaultPCList }catch [exception] { $erlog+="[Couldn't make pclist]$($error[0])"; write-host "Errors man fix it bro"; return $false }
    }else{ [string[]]$PCList = @(get-content -path $defaultPCList); if(!($PCList.count -gt 0)){write-host "ADD PCs TO PCLIST AND RERUN"; return $false }else{ return $PCList}}
  }
 <#-------------------------------------------------------------------------------------------------------
 PCListEdit
 ----------------------------------------------------------------------------------------------------------#>
  function PCListEdit([string]$regCmd) { 
    Invoke-Expression $regCmd;                                              
    set-location -path $PSScriptRoot            <# side-effect #>                    
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
   function getCreds([string]$regCmd,[int]$tried=0,[string]$user=$runAsUser,[string]$m="ADMIN TO AUTHENTICATE ON REMOTE MACHINES.(FQDN)") {
     Invoke-Expression $regCmd;
     if( $tried -gt 3){ $erlog += "Credentials not valid"; return $false }
     try{ $creds=get-credential -user $user -Message $m; 
       if(($null -eq $creds) -or (!($creds.Password.Length -gt 0)) ){ write-host "Password invalid";$tried++; getCreds -tried $tried; 
       }else{ return $creds; }
     }catch [exception] { $erlog +=return $false; }
   }
  <#------------------------------------------------------------------------------------------------
  GETCREDS: calls internal getUser > getPass > makes and returns credential (KEEP FOR REFERENCE/FUTURE INTEGRATION)
  -------------------------------------------------------------------------------------------------#>
 <# function getCreds([string]$runAsUser) {
      function getUser{ try{ [string]$u = read-host "Run As User"; return $u; }catch{ log -msg "GC:GU:$($error[0])"; return "False"; }}
      function getPass{ try{ $pw=read-host "password(encrypted)" -AsSecureString; return $pw; }catch{ log -msg "GC:GP:$($error[0])"; return "False"; }}
      try{ write-host "CREDENTIALS"; if($null -eq $runAsUser){$runAsUser = getUser} if($runAsUser -eq "False") { return $false } $pw = getPass; if($pw -eq "False") {return $false} 
           $creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $runAsUser, $pw; return $creds;
      }catch{ log -msg "GC:$($error[0])"; return $false }
      write-host "NO CREDENTIAL RETURNED"
    }#>
  <#---------------------------------------------------------------------------------------------
  UtilityLoop - NON-INTERACTIVE
  ----------------------------------------------------------------------------------------------#>
  function UtilityLoop([string]$regCmd,$creds,[int]$run,[string]$info,[string]$startTime,[boolean]$state,[ref]$erlog) {
    invoke-expression $regCmd;  
    if($state -eq $false) { $erlog.value += "[UL:Run:$($run):$($error[0])"; return $false }   <# THIS isnt right #>
    if(!($run -eq 0)){write-host "WAITING $cadence SECONDS"; start-sleep -Seconds $cadence}
    if($null -eq $creds) { $creds = getCreds } if(!($creds)){ return $false }
    $LoopTimer = [Diagnostics.Stopwatch]::StartNew();
    if($null -eq $run) { $run = 0 }
    if(($null -eq $startTime) -or ($run -eq 0)) { [string]$startTime = "$(Get-Date -format ('yyyy/MM/dd hh:mm'))" }
    [string[]]$pclist = PCListCheck -defaultPCList $defaultPCList;
    $state = inventory1 -creds $creds -pclist $pclist -injectInfo $info -cacheReset; 
    if(!($state)){return $false}
    $run = $run + 1;
    [string]$info = "[TIMINGS] RUN:$($run) |LASTRUN(SECONDS):$($LoopTimer.elapsed.totalseconds) | STARTED: $($startTime)";
    $LoopTimer.stop();
    UtilityLoop -creds $creds -run $run -info $info -startTime $startTime -state $state;
  }
  <#----------------------------------------------------------------------------------------------------------------------
  Interactive
  -----------------------------------------------------------------------------------------------------------------------#>
  function Interactive([string]$regCmd=$gRegCmd,$creds=$creds,[boolean]$state=$false) { 
    invoke-expression $regCmd;
    try{ 
        read-host "PRESS ENTER TO START"; $startTime = "$(Get-Date -format ('yyyy/MM/dd hh:mm'))";
        if(inventory1 -pclist $pclist -creds $creds -cacheReset) { $state = $true; }
    }catch [exception] { $erlog.value += "$(error[0])"; return $false }
    return $state;
  }

  <#----------------------------
  Logging and IDs
  ----------------------------#>
  function funcRegister([string]$func,[ref]$idSum,[switch]$getRegCmd,[ref]$erlog) {
    [string]$regCmd =               'funcRegister -func $($MyInvocation.MyCommand.Name) -idSum ([ref]$idSum) -erlog ([ref]$erlog)';
    if($getRegCmd) { return $regCmd; } <# Initially called by all sequences then passed to function to invoke as first job #>
    try{ 
      function setId([string]$func) { $state=$false;
        if($null -eq $funcTbl[$func]) { $funcTbl[$func] = $idSum.Value++;}    <# hashtbl is passed by ref by def since it's obj #>
        if($funcTbl[$func] -eq $idSum.value) { $state=$true;} $poop = $idSum.Value; if($dev){ write-host "$func = $poop" }
        return $state;
      }
      if(setId($func)){ $state=$true; }
    }catch [Exception] { $erlog.value += "$($myInvocation.MyCommand.Name):$($error[0])";$state=$false}
    return $state;
  }
  
  function Log([int]$id,[int[]]$fCodes,[string]$m="0") { 
    if(!(test-path -path $logFile)) { try{ new-item -ItemType file -Path $logFile }catch{ $m="COULD NOT MAKE LOG FILE. LOGGING INTERNALLY"; return $false}
    }
    <#PREREQ STUFF#>
    [string[]]$arrfCodesMask=@($null)*($fCodes.length); [string[]]$fcUnmasked=@($null)*($fCodes.length);
    for($i=0;$i-lt($fCodes.count);$i++) { 
      if($null -eq $fCodes[$i]) { $arrfCodesMask[$i] = 'x';$fcUnmasked[$i]="-1";                          <# -1 means not run in this conception. may not use #>
      }else{ $arrfCodesMask[$i] = "$($fCodes[$i])"; $fcUnmasked[$i]="$($fCodes[$i])"}
    }
    [string]$strfCodesMask=("$(fCodesMask)").replace(' ',''); [string]$strFCUnmasked=("$($fcUnmasked)").replace(' ','');
    [string]$L="|$(get-date -Format "yyyyMMddhhmmss")|$($arrFCodesMask)|$($id)|$($m)|"; $erlog += $L; if($dev) { write-host "$($L)"; }
    $L | out-file -FilePath $logFile -append; write-host "THERE WERE ERRORS. CHECK LOG";
    }
  <#---------------------------------------------------------------------------------------------------
  INITIALIZE ARGS 
  ----------------------------------------------------------------------------------------------------#>
  [string[]]$erlog =              @();
  [hashtable]$funcTbl=            @{};
  [boolean]$state =               $true
  [int]$idSum =                   12;
  [string]$gRegCmd=               '[string]$regCmd=(funcRegister -getRegCmd); invoke-expression $regCmd;'
  Invoke-Expression $gRegCmd;
  $gregCmd;
  $erlog;

  $creds=getCreds -regCmd $gRegCmd -user $runAsUser -erlog ([ref]$erlog); if(!($creds -eq $false)) {
    if($start -or $i) {                                 [string[]]$pclist = PCListEdit -regCmd $gRegCmd -erlog ([ref]$erlog); 
      if(!($pclist -eq $false)){                          $state = Interactive -regCmd $gRegCmd -erlog ([ref]$erlog);
        if($state) {                                        $state = UtilityLoop -regCmd $gRegCmd -creds $creds -run 1 -info "CONTINUING QUERIES IN LOOP" -startTime $startTime -state $true; 
        }else{$erlog+="Sequence failed:$($error[0])";       $state = $false; }
      }else{$erlog+="Getting PCList failed:$($error[0])"; $state = $false; }

    }elseif($utility -and (!($loop))) {                   [string[]]$pclist=PCListCheck; 
      if(!($pclist -eq $false)) {                           $state = Inventory1 -pclist $pclist; 
        if($state){write-host "Finished utility run";}
      }
    }elseif($utility -and $loop) {                        $state = UtilityLoop -creds $creds -run 1 -info "CONTINUING QUERIES IN LOOP" -startTime $startTime -state $true;
    }elseif($pclistedit) {                                $state = PCListEdit; write-host "PCLIST EDITED. RERUN TO USE" }
  }
  if(!($state)) { 
    if($dev){ $erlog; } 
    write-host "Masked log goes here"; write-host "Errors encountered. See $($logFile)";  
  }
  
  #if(!($state)){rpt(0,)}else{return 
  }
  
  initialize_inventory -start -dev