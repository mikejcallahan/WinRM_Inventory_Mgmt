param([switch]$raw)
function getUserByTempFolder([switch]$raw) {
<# 
.DESCRIPTION 
 Get users from c:\users. Get mod time of each temp folder. Sort descending
 concat username and sorted time together using common indices (creates a ref of the correct order of users)
 reorder names into desc order excluding system and admin users.
 raw switch will return all users sorted. Without switch you get the top result excluding admins (most likely assignee of the PC)
.OUTPUTS <string[]>
#>
  <#<dependency>#>#[string[]]$forboden = @()
  #"ADMINISTRATOR","$($env:COMPUTERNAME)$","PBSENV","ADMIN","SETUP","ADMINISTRATOR.PBSDOM","PUBLIC","BLOCK64ACT");<#<dependancy>#>
  set-location -path $PSScriptRoot
  if(test-path -path ".\PrimaryUserEstimator_IgnoreList.txt") {[string[]]$forboden = @(get-content -Path ".\PrimaryUserEstimator_IgnoreList.txt"); $forboden += "$($env:COMPUTERNAME)$","PUBLIC","ADMINISTRATOR","DEFAULT"
  for($v=0;$v-lt($forboden.count);$v++) { $forboden[$v] = $forboden[$v].toupper() }
  }else{ new-item -Path ".\PrimaryUserEstimator_IgnoreList.txt" -ItemType file | out-null; start-process explorer -erroraction SilentlyContinue -args ".\PrimaryUserEstimator_IgnoreList.txt"; 
  return "PLEASE ADD TO IGNORE LIST USERNAMES TO IGNORE. NO QUOTES OR COMMAS - 1 PER LINE ('COMPUTERNAME', 'ADMINISTRATOR', 'PUBLIC' & 'DEFAULT' WILL BE SKIPPED AUTOMATICALLY)" }
  try{ $userfolders = @(Get-childitem "c:\users\" -Directory | Sort-Object -Property {$_.LastWriteTime} -Descending) 
    [string[]]$ulist = @(); [string[]]$uTimes = @(); [string[]]$uListValid = @(); [string[]]$uListPrep = @()
    For($i=0;$i-lt$userfolders.count;$i++) { [string]$n = $userfolders[$i] | select Name; [string]$nn = ($n.replace("@{Name=","")).replace("}",""); $ulist += $nn }
    forEach($u in $ulist){ if(Test-path -Path "c:\users\$($u)\appdata\local\temp") { 
      try{ [string]$temp = (Get-Item -Path "c:\users\$($u)\appdata\local\temp" -erroraction stop | select { $_.LastWriteTime.toString("yyyyMMddhhmm")})
        $t = ($temp.replace('@{ $_.LastWriteTime.toString("yyyyMMddhhmm")=',"")).replace("}","")
        $uTimes += $t; $uListPrep += $u
      }catch{ 
       continue
    }}}
    $temparr = @($null) * $uListPrep.count; $tempArr2 = @($null) * $uListPrep.count                                                  
    for($i=0;$i-lt$uTimes.count;$i++) { $tempArr[$i] = "$($uTimes[$i])" + "$($uListPrep[$i])" }   
    $uTSorted = $uTimes | sort-object -Descending                                                 
    for($z=0;$z-lt$uTimes.Count;$z++) { for($i=0;$i-lt$uTimes.count;$i++) { if($temparr[$i].contains($uTSorted[$z])) { $tempArr2[$z] = ($tempArr[$i]).replace("$($uTSorted[$z])","") # this is where the magic happens
    }}}
    [string[]]$tempArr3 = @()
    if(!$raw) { foreach($a in $tempArr2) { if(!($forboden -contains $a.toupper())) { $tempArr3 += $a }} 
    return $tempArr3[0] } # TOP RESULT USERNAME MINUS ADMIN ACCOUNTS
    else { return $tempArr2} # FULL LIST OF USERNAMES SORTED
  }catch { write-host $error[0]; return $false }
}
if($raw){getUserByTempFolder -raw} else { getUserByTempFolder }
