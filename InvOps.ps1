param([string]$store,[string[]]$offPCs,[string[]]$headers)

function Initialize_InventoryOps([string]$store,[string[]]$headers,[switch]$test) {
  [int]$updateSaveFileDelay = 15; 

  
  function getThisModule ([string]$m) { <# WANT TO BUILD APART FROM AD QUERY. DECOUPLE THINGS. THINKING SEPARATE UPDATE PCLIST SOLUTION #>
  if(Get-Module | Where-Object {$_.Name -eq $m}) { return $true; try{ Import-Module $m -erroraction Stop -warningaction ignore; return $true }catch{ return $false }
  }elseif(Get-Module -ListAvailable | Where-Object {$_.Name -eq $m}) { write-host "[IMPORTING] $m"; try{Import-Module $m -ErrorAction Stop -WarningAction ignore; return $true }catch{ return $false } 
  }elseif( Find-Module -Name $m | Where-Object {$_.Name -eq $m}) { write-host "[INSTALLING MODULE] $m"; try{ Install-Module -Name $m -Force -Scope CurrentUser; Import-Module $m; return $true }catch{ return $false }
  }else{ return $false }
  }

  function InventoryOps([string]$store,[string[]]$headers,[switch]$test) { 
    
    function makeDirs([string]$store){ Set-Location -path $store; $state = $false;
      try{    if(!(test-path -path "$($store)\primary")) { New-Item -path "$($store)\primary" -ItemType Directory -ErrorAction Stop | out-null }
              if(!(test-path -path "$($store)\PCTest")) { New-Item -path "$($store)\PCTest" -ItemType Directory -ErrorAction Stop | out-null }
              $state = $true
      }catch{ $global:erlog += "[makeDirs][terminating]$($error[0])"; continue }
      return $state;
    }
    <#--------------------------------------------------------------------------------------------------------------------------------------------------------
    ConstructPCs:
    .DESCRIPTION Makes PC objects. Takes <string[]>. Uses split to make array. Uses '/' as delim: (0)REPORT PATH (1)SERIAL (2)PC NAME (3)USERS[] Returns <object[]>
    --------------------------------------------------------------------------------------------------------------------------------------------------------#>
    function constructPCs([string[]]$splitnames,[string]$store,[switch]$test) {  set-location -path $store; #write-host "CONSTRUCT $store";
      [pscustomobject[]]$dirtyPCs = @(); if($test) { [string]$rawRepo = "$store\PCTest" }else{ [string]$rawRepo="$store\PC" } 
      try{ for($i=0;$i-lt($splitNames.count);$i++) { 
             [string[]]$idxKeys =     "$($splitnames[$i])" -split "/"; 
             [string]$users =         ($idxKeys[3]).replace(' ',','); # FIX IN FUTURE. MAKING COMMA SEP FOR MULTI USER IN REPORT. THIS FROM 2+ USERS SIGNED IN 
             [string]$dateMade =      (Get-ItemProperty -Path "$rawRepo\$($idxKeys[0])" | select-object -ExpandProperty LastWriteTime).toString("yyyyMMddhhmm")
        
             <# APPS LIST: TO OBJECT[] >> STRING[] >> STRING; ANNOYING PS CASTING PATTERN. FLAT STR W/ PROP SYNTAX FOR EASY PS CSV IMPORT/EXPORT. SMARTER WAYS PENDING --------------------#>
             $apps =  @(import-csv -path "$($rawRepo)\$($idxKeys[0])"); [string[]]$sApps = @($apps | Select-Object -Property "Name","Version","Summary","CanonicalId","InstallLocation","InstallDate","UninstallString","QuietUninstallString","ProductGUID") 
             [string]$flatApps = "$($sApps)";

             <# MAKING PC OBJECT ----------------------------------------------------------------------------------------------------------------------#>                                           
             $PC =  New-Object -TypeName PSCustomObject -Property @{InvID='';Serial=("$($idxKeys[1])").ToString(); Name=$idxKeys[2]; Users=$users; Apps=$flatApps; Drivers=''; Location=''; Date=$dateMade; File="$($idxKeys[0])" }
             $dirtyPCs += $PC;
           }
      }catch{ $global:erlog += "[constructPCs]$($error[0])"; return $null }
      if($test) { write-host "LAST DIRTYPC OBJ SERIAL: $($dirtyPCs[-1].serial)" }
      #if($null -ne $dirtyPCs[0]) { return $dirtyPCs }else{  return $null  }
      return $dirtyPCs
    }
    
   <#---------------------------------------------------------------------------------------------------------------------------------------------------------
   ReportNameParser:
   .DESCRIPTION Takes filenames[] and returns array of "<filename>/<serial>/<computername>/<user>" strings. precursor to pc constructor. should be in constructor.
   --------------------------------------------------------------------------------------------------------------------------------------------------------- #>
    function ReportNameParser([string[]]$files) { [string]$m = ''; [string[]]$splits = @(); 
      for($z=0;$z-lt($files.count);$z++) {   $f = $files[$z];                     <#   FILE NAME STYLE "TESTPCQ(ABC1234)_USER2_-_Apps_-.csv" #>
        if($f -match "^.*$") {               $m = "$($matches[0])" }              <# 0 FILENAME     ( REGEX 4 SYMETRY  ) #>
        if($f -match '\((.*?)\)') {          $m = "$($m)" + "/$($matches[0])" }   <# 1 SERIAL       ( GETS '(' TO ')'  ) #>
        if($f -match "^.*(?=\()") {          $m = "$($m)" + "/$($matches[0])" }   <# 2 COMPUTERNAME ( GETS [0] TO '('  ) #>
        if($f -match "(?<=_)[^_]+(?=_-_)") { $m = "$($m)" + "/$($matches[0])" }   <# 3 USER         ( GETS '_' TO '_-' ) #>
        $m = (($m).replace('/(','/')).replace(')/','/'); $splits += $m;           <#   PARENTHESES REMOVE FROM SERIAL BECAUSE REGEX OR ME CAN'T FIGURE IT OUT #>
      }return $splits
    }
    <# -------------------------------------------------------------
    PCSave:
    .DESCRIPTION Takes obj[] writes to file as csv export.
    ---------------------------------------------------------------- #>
    function PCSave($PCObjects,[string]$savePath,[string]$msg) {
      if($null -eq $msg){$msg=''}
      foreach($pc in $PCObjects) { [string]$fileName =$pc.Serial; logThis -text "$msg [SAVE]$($pc.Serial)][$($pc.Name)][$($pc.Users)]"; 
        $pc | Export-csv -path "$($savePath)\$($fileName)" -force -NoTypeInformation;
      }
    }
    <# -------------------------------------------------------------------------------
    logThis: Logging yo
    -------------------------------------------------------------------------------- #>
    function logThis([string]$text){
      [string]$logPath = ".\Ops.log"
      if(!(test-path -path $logPath)) { New-Item -Path $logPath -ItemType File | out-null }
      [string]$time = (Get-Date).toString("yyyy/MM/dd HH:mm:ss")
      [string]$formatText = "[$time] $text"
      Add-content $logPath -value $formatText
    }
    <#--------------------------------------------------------------------------------------------------------------------
    INVENTORYOPS SEQUENCES: NOTES $Store is referenced too much. Should just pass target dir which includes parent store
    ---------------------------------------------------------------------------------------------------------------------#>
    function sequence1([string]$store,[string]$PCbulk,[string]$PCprimary,[switch]$test) { 
      [pscustomobject[]]$diskApps = @();[pscustomobject[]]$diskUsers = @();
      #[hashtable]$keyMap = @{}
      [string[]]$global:erlog = @();if($null -eq $PCbulk) { [string]$PCbulk = "PC" } if($null -eq $PCprimary) { [string]$PCprimary = "primary"; }
      #[string[]]$splitNamesTest = @("_TESTPC(123ABCD)_USER_-_Apps_-.csv/123ABCD/_TESTPC/USER","_TESTPCQ(ABC1234)_USER2_-_Apps_-.csv/ABC1234/TESTPCQ/USER2")
      try{ 
        if($test) { $PCprimary = "primaryTest"; $PCbulk = "PCtest"}
        if(makeDirs -store $store) { 

          <# THESE ARE STORED PC OBJECTS(IN CSVs). THE DATABASE IN ALL IT'S GLORY. JUST GETTING FILENAMES (WHICH IS PC SERIAL #) #>
          [string[]]$saves = @(Get-ChildItem -path "$store\$pcprimary");

          <# THESE ARE PC REPORTS OF SOFTWARE. FILENAMES INCLUDE PC NAME, SERIAL, USERNAME AND THE REPORT TYPE EX:"-_APPS_-" #>
          [string[]]$files = @(Get-ChildItem -path "$store\$PCbulk");
          
          <# LOOP THROUGH BOTH AND FIND FILES WHICH CONTAIN SAVED PC SERIALS AND NOT. COLLECTING INITIAL MATCHES & DUPLICATES SEPARATELY FOR NOW #>
          [string[]]$match=@(); [string[]]$noMatch=@(); [int[]]$savesIdxs=@(); [string[]]$dupIdxs = @();
          for([int]$z=0;$z-lt($files.Count);$z++)  {                                                                <# ITER RAW REPORT FILES    #>
            for([int]$x=0;$x-lt($saves.count);$x++)  {                                                              <# ITER SAVED PC FILES      #>
              if( ($files[$z].contains($saves[$x])) -and (!($savesIdxs -contains $x)) ) { $savesIdxs += $x; $match +=  "$($files[$z])";       <# PARALLEL ARRAYS #>
              }elseif(($savesIdxs -contains $x) -and ($x-eq(($saves.count) -1))) {        $dupIdxs   += "$($z)/$($x)" }       <# Concat indexes of duplicates at files[z]/saves[x]  #> 
              if($x-eq(($saves.count) -1)) { if(!($match -contains "$($files[$z])" )) {   $noMatch   += $files[$z] }} <# NO MATCH (NEW PC) #>
          }}
          write-host "|UPDATES:$($match.count) |NEW-PCS:$($noMatch.count) |DUPLICATES:$($dupIdxs.count) |SAVED(ALL):$($saves.count) |REPORTS:$($files.count) ";

          <# MAKE PC OBJECTS FROM MATCH,NOMATCH AND SAVED (SEPARATE SAVE OBJ LISTS FOR MATCH & DUPLICATE CASES) #>
          [string[]]$mSplits = @(reportNameParser -files $match); $objMatchPCs = @(constructPCs -splitNames $mSplits -store $store -test);
          [string[]]$noMSplits= @(reportNameParser -files $noMatch); $objNoMatchPCs= @(constructPCs -splitNames $noMSplits -store $store -test)
          $objSavesMatchPCs = [PSCustomObject[]]::new($savesIdxs.count);
          $objSavesTempPCs = [PSCustomObject[]]::new((($dupIdxs.count) + ($match.count)));
            
          <# SAVED PC LIST FOR MATCH CASE #>
          for($r=0;$r-lt($savesIdxs.count);$r++) { $objSavedPC = import-csv -path "$store\$pcprimary\$($saves[($savesIdxs[$r])])"; $objSavesMatchPCs[$r]=$objSavedPC } 
                     
          <# DUPLICATE UPDATES #> 
          #$objDupCandidates = [PSCustomObject[]]::new($dupIdxs.count); 
          [string[]]$dupSplits = @($null) * ($dupIdxs.count); [string[]]$dupFiles = @($null) * ($dupIdxs.count); $dupFiles.length; $dupSplits.length;
          for($di=0;$di-lt($dupIdxs.count);$di++) { [int[]]$arDup = @($dupIdxs[$di] -split "/"); [int]$idxDupFile = $arDup[0]; [int]$idxDupSave = $arDup[1];
            $dupFiles[$di] = $files[$idxDupFile]; $objSavedPC = import-csv -path "$store\$pcprimary\$($saves[$idxDupSave])"; $objSavesTempPCs[$di]=$objSavedPC;
          }
          [string[]]$dupSplits = @(reportNameParser -files $dupFiles); $objDupPCs = @(constructPCs -splitNames $dupSplits -store $store -test)

            
            function updateAttributeCheck([PSCustomObject[]]$compare,[PSCustomObject[]]$against) { 
              <# relying on Parallel arrays of PC objects. Against should be saved(db objects), compare should be the new objects to 'compare' see what I did there.
               if dealing with duplicates Against should be copies of the saved PC objects to keep arrays parallel. Note we are only doing below logic for obj newer than threshold to keep writes down.
               -------------------------------------------------------------------------------------------------------------------------------------------------------------------#>
              <# FOR CONSOLE OUTPUT AND LOG FILE -------------------------------------------------------------------------------------- #>
              $c = $compare.count; [string[]]$whereWeAt = @("CHECK $($c) PCs","LASTWRITETIME CHECK","USER UPDATE CHECK","APP UPDATE CHECK");
              function out([int]$id,[string]$extra,[switch]$log) { $msg= "[$($whereWeAt[$id])]$extra"; write-host "$msg"; if($log){logThis -text $msg} }
              <# -------------------------------------------------------------------------------------------------------- #>
                [int]$id = 0 
                [PSCustomObject[]]$objModifiedPCs =@();              write-host "POOP $($against.count)   | $($compare.count)  "                                                                      
                try{ out -id $id -log;
                  for([int]$a=0;$a-lt($against.count);$a++) { [string]$extra = ""; $id = 0; 
                    [long]$ad = $against[$a].Date; [long]$cd = $compare[$a].Date; if($a -eq 0) { write-host "CHECKING SAVED PC OBJECTS AGAINST NEW REPORTS" }#if(($cd.count) -eq 12) {$unit="MINUTES"}elseif($cd.count -eq 10){$unit="HOURS"}write-host "CHECKING SAVED PC OBJECTS AGAINST NEW REPORTS > $($updateSaveFileDelay) $unit OLD"}
                    if(($cd - $ad) -gt $updateSaveFileDelay) {  $extra+="$($against.Name)| NEW REPORT"; out -id $id -extra $extra -log; <# ----------- CONTINUES UPDATE IF LASTWRITETIME > DELAY. (1) -- #>
                      [string]$serial = "$($against[$a].Serial)"; $extra = "@{$($serial)| NEW REPORT"; out -id ($id++) -extra $extra -log; 
                      [string[]]$newUsers = @(); [string[]]$newApps= @();                                                           
                      [string[]]$au = @(("$($against[$a].Users)") -split ','); [string[]]$an = @(("$($against[$a].Name)") -split ','); [string[]]$aa = @(([string]($against[$a].Apps)) -split '@{'); 
                      [string[]]$cu = @(("$($compare[$a].Users)") -split ','); [string[]]$cn = @(("$($compare[$a].Name)") -split ','); [string[]]$ca = @(("$($compare[$a].Apps)") -split '@{');
                      if($against[$a].Users -ne $cu) { <# ------------------------------------------------------------------------------------------------------- USER UPDATE (2) ---------------------- #>
                        $extra = "USER UPDATE"; out -id ($id++) -extra $extra -log;
                        for($i=0;$i-lt($cu.count);$i++) { <# ---------------------------------------------------------------------------------------------------- USER IDENTIFIED AFTER PREV UNKNOWN #>
                          if(($cu[$i] -ne "UNKNOWN")) { if($au[$i] -eq "UNKNOWN") { $newUsers += $cu[$i] }elseif(!($au[$i].contains($cu[$i]))) { $newUsers += $cu; } $extra ="NEW USER| [$($cu[$i])]"; out -id $id -extra $extra -log; }
                        }foreach($oldUser in $au) { if($oldUser -ne "UNKNOWN") { $newUsers += $oldUser; $newUsers = $newUsers | sort -Descending; }} $against[$a].Users = ("$($newUsers)" -replace(' ',','));
                      } <# -------------------------------------------------------------------------------------------------------------------------------------- APP UPDATE (3) ----------------- #>
                      if("$($aa)" -ne "$($ca)") { <# ------------------------------------------------------------------------------------------------------------ CAST STR APP LISTS. COMPARE CONTINUE IF DIFFERENT #>
                        $extra="APP UPDATE"; out -id ($id++) -extra $extra -log; 
                        [string[]]$aIds = @($null) * ($aa.count);[string[]]$aNames=@($null) * ($aa.count); for($z=0;$z-lt($aa.Count);$z++) { $aIds[$z] = ($aa[$z] -split ';')[3]; $aNames[$z] = ($aIds[$z] -split ';')[0]; } #write-host $aNames[0]
                        [string[]]$cIds = @($null) * ($ca.count);[string[]]$cNames=@($null) * ($ca.count); for($x=0;$x-lt($ca.count);$x++) { $cIds[$x] = ($ca[$x] -split ';')[3]; $cNames[$x] = ($cIds[$x] -split ';')[0]; } #write-host "{$($cNames[0]) | $($ca[0]) }"
                        
                        #$aa
                        write-host "$($against[$a].Name) | $($compare[$a].Name) | $($aa.count) | $($ca.count) | $($cn) | $($cu)" #not parrallel figur out why
                        write-host "test"
                        <#
                        foreach($poo in $aids) {write-host "$($poo)"}
                        write-host "************************************************************"
                        foreach($poo2 in $cids) {write-host "$($poo2)"}
                        write-host "********************************************************************"
                        foreach($poo3 in $anames) {write-host "$($poo3)"}
                        write-host "********************************************************************"
                        foreach($poo4 in $cnames) {write-host "$($poo4)"}
                        #>
                        break
                        
                        for($q=0;$q-lt($aa.count);$q++) {  
                          if(!($cNames -contains $aNames[$q] )) { <# -------------------------------------------------------------------------------------------- APP REMOVAL CHECK ------------#>
                            $extra = "APP WAS REMOVED: $($aIds[$q])"; out -id $id -extra $extra -log; 
                          }else{ <# ----------------------------------------------------------------------------------------------------------------------------- CONTINUE IF NECESSARY ------#>
                            for($w=0;$w-lt($ca.count);$w++) { <# ------------------------------------------------------------------------------------------------ NEW APP INSTALL ---------#>
                              if(!($aNames -contains $cNames[$w])) { $newApps += "@{$($ca[$w])";$extra = "NEW APP| $($cIds[$w])"; out -id $id -extra $extra;     # not logging just console, but even that's too much | rethink
                                <# ------------------------------------------------------------------------------------------------------------------------------ COMPARE CANONICAL IDs (HAS VER CHANGE IF APPLICABLE) -- #>
                              }elseif($aIds[$q] -ne $cIds[$w]) { $newApps += "@{$($ca[$w])"; $extra = "APP UPDATE| NEW:$($cIds[$w])"; out -id $id -extra $extra; }
                            }
                          }if(!($newApps -contains "@{$($aa[$q])")) { $newApps += "@{$($ca[$q])" } 
                        }$against[$a].Apps = "$($newApps)";
                      }$objModifiedPCs += $against[$a];<# ------------------------------------------------------------------------------------------------------- PACK EM LIKE SARDINES ----------#>
                    }
                  }
                }catch{ $er = "$extra| $($error[1])"; $global:erlog += $er; out -id $id -extra $extra -log; return $null }
                if($null -ne $objModifiedPCs[0]) { return $objModifiedPCs; }else{ return $null }
              } 
            <# ---------------------------------------------------------------------------------------------------------------------------------------------- END ATTRIBUTE CHECK/UPDATE ---- 
             CALL ATTRIBUTE UPDATE FUNC COMPARE MATCHES AGAINST SAVED PCs THEN TAKE THE RETURNED UPDATED SAVED OBJs AND COMPARE DUPLICATES AGAINST THAT
            ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------#>
              $objUpdates = updateAttributeCheck -compare $objMatchPCs -against $objSavesMatchPCs                                                             <# MATCH PCs SECTION #>
              if(($null -ne $objDupPCs) -and ($null -ne $objUpdates)) { $objUpdates = updateAttributeCheck -compare $objDupPCs -against $objUpdates }         <# DUPLICATES SECTION #>
              if($null -ne $objUpdates) { PCsave -PCObjects $objUpdates -savePath ".\$pcprimary" -msg "saving $($objUpdates.count) PCs";
              }else{ write-host "NO UPDATES"; return $null } 
             <# we update the db if delay thresh exceeded #>
              
                
            #  if(((($objMatchPCs[$idxDupSave].Date) - ($objFromSaves.Date)) -gt $updateSaveFileDelay)) { $objSavesUpdates[$di] = 
                <# UPDATE USERS #> 
             #   [string]$dupFile = @(reportNameParser -files $files[$idxDupFile]); 
              #  [string[]]$su = @("$($objFromSaves[$di].Users)" -split ','); $mu=@("$($objMatchPCs[$di].Users)" -split ',')  # u dont want matchpcs homie
             #   if(!($objFromSaves[$di].Users).contains($objMatchPCs[$di].Users) ){ 
               #   $objFromSaves.Users = ("$($objFromSaves.Users),$($objMatchPCs[$di].Users)").trim(); logThis -text "[UPDATE USERS][$($objFromSaves[$di].Serial)][$($objFromSaves[$di].Users)]" }
                <# UPDATE APPS #>
               # if(!$objFromSaves[$di].Apps)
             #  $objDupPC = @(constructPCs -splitnames $dupFile -store $store -test)
             # $objSavesUpdates[$di] = $objFromSaves  } 
           

            <# UPDATE COMPUTERNAME #>

              <# SAVE NO MATCH(NEW) PCS | SAVE UPDATED PCS #>
             # PCSave -PCObjects $objNoMatchPCs -savePath "$store\Primary"; 
             # PCSave -PCObjects $objSavesUpdates -savePath "$store\Primary"
              #for($i=0;$i-lt($objSavesTempPCs);$i++) { if($null -eq $objSavesTempPCs[$i]) { if }
              #write-host "MATCHES: $($objSavesMatchPCs.count) | SAVES W/ POTENTIAL UPDATES: $($objSavesTempPCs.count) | DUP: $($objDupPCs.count) | updates: $($objUpdates.count)"
              #write-host "|UPDATES:$($match.count) |NEW-OBJ:$($objNoMatchPCs.count) |MATCH(ALL):$($objMatchPCs.count)";
               }
          
        }catch{$erlog += "[TESTSEQ]$($error[0])"}
    
    }
    <#--------------------------------------------------------------------------------
    Ops args
    ---------------------------------------------------------------------------------#>
    if($test){ sequence1 -store $store -test }else{ sequence1 -store $store } # DO TEST FUNCTION IN V2
  }
  <#-------------------------------------------------------------------------------
  initialize args
  --------------------------------------------------------------------------------#>
  $global:erlog = @();
  if($test){inventoryOps -store $store -test }else{ inventoryOps -store $store }
 } 
 
<#-----------------------------------------------------------------------------
Global (outer) args - variables here are stored in session
-------------------------------------------------------------------------------#>
[string]$store = split-path -parent $MyInvocation.MyCommand.Definition  
write-host "INITIALIZING OPERATIONS: $($store)"
set-location -path $store
try{ initialize_inventoryOps -test -store $store  }catch{ write-host "$($error[0])"; pause }


#InitInvSeq
<#function InventoryOps([string]$store,[string[]]$headers,[switch]$test) {
    function logEr([string]$e) {
      set-location -path "$PSScriptRoot";[string]$erLogPath = ".\InvOps.log"
      if(!(test-path -path $erLogPath)){New-Item -path $erlogpath -itemtype file -force | out-null }
      [string[]]$code,[string[]]$er = @(); for($i=0;$i-lt($e.count);$e++){$er+=($e[$i] -split "_")}
      Add-Content -Path $erLogPath -Value $er;
    # TEMP FOR DEV
    }
    function IDfactory([string]$key) { #does nothing yet
    <#$server1 = [PSCustomObject]@{
    ServerName = "ServerA"
    IPAddress  = "192.168.1.10"
    Role       = "Web Server"#>

   <# $data = Import-Csv -Path 'data.csv'
 
      $data | ForEach-Object {
        [PSCustomObject]@{
        FirstName = $_.First
        LastName = $_.Last
        Age = $_.Age
        }
      }
      if(!(test-path -path ".\util\ids")) { try{new-item -Path ".\util\ids" -itemtype File }catch{ write-host "IDS FILE";break}
      }else{$dirtyIDs = @(Import-Csv -path ".\pIds" -Header "invId","Serial","Computer","User")
      #@(Import-Csv -path ".\ids" -Header "Name","Version","Summary","CanonicalId","InstallLocation","InstallDate","UninstallString","QuietUninstallString","ProductGUID")}
   
    }}#><#[int[]]#>
    
    
    <#----------------------------------------------------------------------------------------------------------------------------------------------
    ReportNameParser 
    .DESCRIPTION Processes filenames. Makes parallel arrays of report name, serials, comps, user, concats cross-section into string for each report. 
    Report strings are added to <string[]> and returns that. Lots of redundant steps in this service. Should be rewritten using regex maybe return jagged array
    ------------------------------------------------------------------------------------------------------------------------------------------------#>
    <#
    function ReportNameParser([switch]$test,[string]$store) {  if($test) { [string]$rawRepo="$($store)\PCTest" }else{ [string]$rawRepo="$($store)\PC"} 
      try{ [string[]]$reports = @(Get-ChildItem -Path "$rawRepo" ); [string[]]$comps,[string[]]$serials,[string[]]$users,[string[]]$splitNames = @();
        if($reports.count -eq 0) { throw "$rawRepo EMPTY" } 
        for($i=0;$i-lt($reports.count);$i++) {                                                                          
          [string]$internButcher = "$($reports[$i])";                                                                   [int]$intComps = ($reports[$i]).indexOf('('); 
          [string]$compName =      ($reports[$i]).substring(0,$intComps); $comps += $compName;                          $internButcher = $internButcher.replace($compName,'');
          [string]$serialNu =      (($internButcher).substring(0,$intSerial)).replace('(','');                          $serials +=      $serialNu; $internButcher = $internButcher.replace("($serialNu)",'');
          [int]$intUser =          ($internButcher).indexOf('-'); 
          [string]$userName =      ((($internButcher).substring(0,$intUser)).replace('_','')).replace('-APPS-.csv',''); 
          $users +=                $userName;                                                                           $internButcher = $internButcher.replace("$userName-",'');
          $splitNames +=           "$($reports[$i])/$($serials[$i])/$($comps[$i])/$($users[$i])" 
        }
      }catch{ [string]$er = "[ReportNameParser]$($error[0])"; $global:erlog += $er; return $null }
      return $splitnames;
    }#>
<#--------------------------------------------------------------------------------------------------------------------------------------------------------
    check4Duplicates
    .DESCRIPTION Compares object[] with object[] based on key. Returns indices of matches concatenated in string which is added to string[]. 
    --------------------------------------------------------------------------------------------------------------------------------------------------------#>
    #function makeItRight($thing,[switch]$pc,[switch]$user,[switch]$apps){}
    <#function check4Duplicates([pscustomobject[]][ref]$check,[pscustomobject[]][ref]$against,[string]$pkey,[switch]$test) {
      try{ 
        #if($test) { write-host "Check4Duplicates|DirtyPCs.Count:$($check.count)|diskPC.Count:$($against.count)|pKey:$pkey" }
        #[string[]]$AgainstKeys = @($against | Select-Object -ExpandProperty $pkey).$pkey
        [int[]]$A = @() * ($against.count);[int[]]$C = @() * ($check.count);
        for($i=0;$i-lt($check.count);$i++) { for($z=0;$z-lt($against.count);$z++) { if($against[$z].$pkey -eq $check[$i].$pkey) { $A[$z] = $i; $C[$i] = $z }}} 
        #if($test) { write-host "CHECK4DUP:[diskPC.COUNT]:$($against.count)|[AgainstKeys[0]]$($AgainstKeys[0]) [INDEXES]A:$($A[0]) C:$($C[0]) (A & C = diskPC & dirtyPC Matches respectively)" }
        [string[]]$Hits = @(); if($A.count -gt 0) { for($y=0;$y-lt($A.count);$y++) { $Hits += "$($A[$y])/$($C[$y])"; if($test) { write-host "CHECKDUPS:[hits]$($hits.count)|" }}}
      }catch{ write-host $error[0] }
      if($null -eq $Hits) { return $null }else{ return $Hits }
    }#>
