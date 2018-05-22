# Note: By default, psake behaves as if $ErrorActionPreference = 'Stop' had been set.
#       I.e., *any* PS errors - even nonterminating ones - abort execution by default.

properties {
  # Supported parameters (pass with -parameter @{ <name> = <value>[; ...] }):
  #
  #   SkipTest[s] / NoTest[s] ... [Boolean]; if $True, skips execution of tests
  #   Force / Yes ... [Boolean]; skips confirmation prompts
  #
  $p_SkipTests = $SkipTests -or $SkipTest -or $NoTests -or $NoTest
  $p_SkipPrompts = $Force -or $Yes

  $p_configPsdFile = "$HOME/.new-moduleproject.psd1"

}



# If no task is passed, list the available tasks. 
task default -depends ListTasks

task ListTasks -alias l -description 'List all defined tasks.' {
  # !! Ideally, we'd just pass through to -docs, but as of psake v4.7.0 on
  # !! PowerShell Core v6.1.0-preview on at least macOS, the formatting is broken.
  # !! Sadly, -docs use Format-* cmdlets behind the scenes, so we cannot
  # !! directly transform its output and must resort to text parsing.
  (Invoke-psake -nologo -detailedDocs -notr | out-string -stream) | % { 
    $prop, $val = $_ -split ' *: '
    switch ($prop) {
      'Name' { $name = $val }
      'Alias' { $alias = $val }
      'Description' {
        if ($name -notmatch '^_') { # ignore internal helper tasks
          [pscustomobject] @{ Name = $name; Alias = $alias; Description = $val }
        }
      }
    }
  } | Out-String | Write-Host -ForegroundColor Green
}

task Test -alias t -description 'Invoke Pester to run all tests.' {
  
  if ($p_SkipTests) { Write-Verbose -Verbose 'Skipping tests, as requested.'; return }
  
  Assert ((Invoke-Pester -PassThru).FailedCount -eq 0) "Aborting, because at least one test failed."

}

task Publish -alias pub -depends _assertMasterBranch, _assertNoUntrackedFiles, Test, Commit -description 'Publish to the PowerShell Gallery.' {

  $moduleName = Split-Path -Leaf $PWD.Path
  $moduleVersion = [semver] (Import-PowerShellDataFile "$($PWD.Path)/${moduleName}.psd1").ModuleVersion

  Write-Verbose -Verbose 'Creating and pushing tags...'
  # Create a tag for the new version
  iu git tag -f -a -m "Version $moduleVersion" "v$moduleVersion"
  # Update the generic 'pre'[release] and 'stable' tags to point to the same tag, as appropriate.
  # !! As of PowerShell Core v6.1.0-preview.2, PowerShell module manifests only support [version] instances
  # !! and therefore do not support prereleases.
  iu git tag -f ('stable', 'pre')[[bool] $moduleVersion.PreReleaseLabel]
  # Push the tags to the origin repo.
  iu git push -f origin master --tags

  assert-confirmed @"
About to PUBLISH TO THE POWERSHELL GALLERY:

  Module:  $moduleName
  Version: $moduleVersion
  
  IMPORTANT: Make sure that:
    * you've run ```Invoke-psake LocalPublish`` to publish the module locally
    * you've waited for the changes to replicate to all VMs
    * you've run ``Push-Location (Split-Path (Get-Module -ListAvailable $moduleName).Path); if (`$?) { Invoke-Pester }``
      and verified that the TESTS PASS
       * on ALL PLATFORMS and
       * on WINDOWS, both in Windows PowerShell and PowerShell Core.

Proceed?
"@

  # Note: -Repository PSGallery is implied.
  Publish-Module -Path $PWD.Path -NuGetApiKey (get-NuGetApiKey)

}

task LocalPublish -alias lpub -depends _assertMasterBranch, _assertNoUntrackedFiles, Test, Commit -description 'Publish locally, to the current-user module location.' {

  $targetParentPath = if ($env:MK_UTIL_FOLDER_PERSONAL) {
    "$env:MK_UTIL_FOLDER_PERSONAL/Settings/PowerShell/Modules"
  } else {
    if ($env:OS -eq 'Windows_NT') { "$HOME\Documents\{0}\Modules" -f ('WindowsPowerShell', 'PowerShell')[[bool]$IsCoreClr] } else { "$HOME/.local/share/powershell/Modules" }
  }
  
  $targetPath = Join-Path $targetParentPath (Split-Path -Leaf $PWD.Path)

  # Make sure the user confirms the intent.
  assert-confirmed @"
About to PUBLISH LOCALLY to:

  $targetPath

which will REPLACE the existing folder's content, if present.
  
Proceed?
"@

  # Create the target folder or remove its *contents*, if present.
  if (Test-Path -LiteralPath $targetPath) {
    Remove-Item -Force -Recurse -Path $targetPath/*
  } else {
    New-Item -ItemType Directory -Path $targetPath
  }

  # Copy this folder's contents recursively, but exclude the .git subfolder, the .gitignore file, and the psake "make file".
  Copy-Item -Recurse -Path "$($PWD.Path)/*" -Destination $targetPath -Exclude '.git', '.gitignore', 'psakefile.ps1'
  
  Write-Verbose -Verbose "'$($PWD.Path)' copied to '$targetPath'"

}

task Commit -alias c -depends _assertNoUntrackedFiles -description 'Commit pending changes locally.' {

  if ((iu git status --porcelain).count -eq 0) {
    Write-Verbose -Verbose '(Nothing to commit.)'
  } else {
    Write-Verbose -Verbose "Committing changes to branch '$(iu git symbolic-ref --short HEAD)'; please provide a commit message..."
    iu git add --update .
    iu git commit
  }

}

task Push -depends Commit -description 'Commit pending changes locally and push them to the remote "origin" repository.' {
  iu git push origin (iu git symbolic-ref --short HEAD)
}

task Version -alias v {

  $psdFile = Resolve-Path ./*.psd1
  $htModuleMetaData = Import-PowerShellDataFile -LiteralPath $psdFile
  $ver = [semver] $htModuleMetaData.ModuleVersion

  $choices = 'Major', 'mInor', 'Patch', 'Retain', 'Abort'
  while ($True) {
    $ndx = read-HostChoice @"
Current version number:

    $ver

BUMP THE VERSION NUMBER
"@ -Choices $choices

    Assert ($ndx -ne $choices.count -1) 'Aborted by user request.'
    if ($ndx -eq $choices.count -2) {
      Write-Warning "Retaining existing version $ver, as requested."
      $verNew = $ver
      break
    } else {
        $verNew = increment-version $ver -Property $choices[$ndx]    
        $ndx = read-HostChoice @"
About to bump to NEW VERSION NUMBER:
      
        $ver -> $verNew
      
Proceed?
"@ -Choice 'Yes', 'Revise'
      if ($ndx -eq 0) { 
        break
      }
    }
  }

  # Update the module manifest with the new version number.
  if ($ver -ne $verNew) {
    update-ModuleManifestVersion -Path $psdFile -ModuleVersion $verNew
  }

}

task EditConfig -alias edc -description "Open the global configuration file for editing." {  
  Invoke-Item -LiteralPath $p_configPsdFile
}

#region == Internal helper tasks.

# # Playground task for quick experimentation
task pg  {
  get-NuGetApiKey -Prompt
}  

task _assertMasterBranch {
  Assert ((iu git symbolic-ref --short HEAD) -eq 'master') "Must be on branch 'master'."
}

task _assertNoUntrackedFiles {
  Assert (-not ((iu git status --porcelain) -like '`?`? *')) 'Workspace must not contain untracked files.'
}


#endregion

#region == Internal helper functions

# Helper function to prompt the user for confirmation, unless bypassed.
function assert-confirmed {
  param(
    [parameter(Mandatory)]
    [string] $Message
  )

  if ($p_SkipPrompts) { Write-Verbose -Verbose 'Bypassing confirmation prompts, as requested.'; return }

  Assert (0 -eq (read-HostChoice $Message -Choices 'yes', 'abort')) 'Aborted by user request.'

}

# Invokes an external utility, asserting successful execution.
# Pass the command as-is, as if invoking it directly; e.g.:
#     iu git push
Set-Alias iu invoke-Utility
function invoke-Utility {
  $exe, $argsForExe = $Args
  $ErrorActionPreference = 'Stop' # in case $exe isn't found
  & $exe $argsForExe
  if ($LASTEXITCODE) { Throw "$exe indicated failure (exit code $LASTEXITCODE; full command: $Args)." }
}

# Increment a [semver] or [version] instance's specified component.
# Outputs an inrecmented [semver] or [version] instance.
# Example:
#   increment-version 1.2.3 # -> [semver] '1.2.4'
function increment-Version {

  param(
    [Parameter(Mandatory)]
    $Version
    ,
    [ValidateSet('Major', 'Minor', 'Build', 'Revision', 'Patch')]  
    [string] $Property = 'Patch'
    ,
    [switch] $AssumeLegacyVersion # with string input, assume [version] rather than [semver]
  )
  
  if ($Property -in 'Build', 'Revision') { $AssumeLegacyVersion = $True }

  if ($Version -is [semver]) {
    $verObj = $Version
  } elseif ($Version -is [version]) {
    $verObj = $Version    
  } else {
    $verObj = $null
    if (-not $AssumeLegacyVersion) {
       $null = [semver]::TryParse([string] $Version, [ref] $verObj)
    }
    if (-not $verObj -and -not ([version]::TryParse([string] $Version, [ref] $verObj))) {
      Throw "Could not parse as a version: '$Version'"
    }
  }

  $arguments = 
    ($verObj.Major, ($verObj.Major + 1))[$Property -eq 'Major'],
    ($verObj.Minor, ($verObj.Minor + 1))[$Property -eq 'Minor']
    
  if ($verObj -is [semver]) {

    if ($Property -eq 'Revision') { Throw "[semver] versions do not have a '$Property' property." }
    if ($Property -eq 'Build') { $Property = 'Patch' }
      
    $arguments += ($verObj.Patch, ($verObj.Patch + 1))[$Property -eq 'Patch']

  } else { # [version]

    if ($Property -eq 'Patch') { $Property = 'Build' }
    
    if ($Property -in 'Build', 'Revision') {
      $arguments += [Math]::Max(0, $verObj.Build) + $(if ($Property -eq 'Build') { 1 } else { 0 })
    }

    if ($Property -eq 'Revision') {
      $arguments += [Math]::Max(0, $verObj.Revision) + 1
    }
    
  }

  New-Object $verObj.GetType().FullName -ArgumentList $arguments

}


<#
.SYNOPSIS
Prompts for one value from an array of choices
and returns the index of the array element
that was chosen.

#>
function read-HostChoice {
  
    param(
      [string] $Message,
      [string[]] $Choices = ('yes', 'no'),
      [switch] $NoChoicesDisplay,
      [int] $DefaultChoiceIndex = -1, # LAST option is the default choice by default.
      [switch] $NoDefault # no default; i.e., disallow empty input
    )

    if ($DefaultChoiceIndex -eq -1) { $DefaultChoiceIndex = $Choices.Count - 1 }

    $choiceCharDict = [ordered] @{}
    foreach ($choice in $Choices) {
      $choiceChar = if ($choice -cmatch '\p{Lu}') { $matches[0] } else { $choice[0] }
      if ($choiceCharDict.Contains($choiceChar)) { Throw "Choices are ambiguous; make sure that each initial char. or the first uppercase char. is unique: $Choices" }
      $choiceCharDict[$choiceChar] = $null
    }
    [string[]] $choiceChars = $choiceCharDict.Keys
    # [string[]] $choiceChars = foreach ($choice in $Choices) {
    #   $(if ($choice -cmatch '\p{Lu}') { $matches[0] } else { $choice[0] })
    # }

    if (-not $NoChoicesDisplay) {
      $i = 0
      [string[]] $choicesFormatted = foreach ($choice in $Choices) {
        [regex]::replace($choice, $choiceChars[$i], { param($match) '[' + $(if (-not $NoDefault -and $i -eq $DefaultChoiceIndex) { $match.Value.ToUpperInvariant() } else { $match.Value.ToLowerInvariant() }) + ']' })
        ++$i
      }

      $Message += " ($($OFS=' / '; $choicesFormatted)): "
    }
      
    while ($true) {
      # TODO: add coloring to prompts.
      # Write-HostColored -NoNewline $Message 
      Write-Host -NoNewline $Message 
      $response = (Read-Host).Trim()
      $ndx = [Array]::FindIndex($choiceChars, [System.Predicate[string]]{ $Args[0] -eq $response })
      if ($response -and $ndx -eq -1) {
        # As a courtesy, also allow the user to type a choice in full.
        $ndx = [Array]::FindIndex($Choices, [System.Predicate[string]]{ $Args[0] -eq $response })
      }
      if ($ndx -ge 0) { # valid input
        break
      } elseif (-not $response -and -not $NoDefault) { # use default
        $ndx = $DefaultChoiceIndex
        break
      }
      Write-Warning "Unrecognized reponse. Please type one of the letters inside [...], followed by ENTER."
    }

    return $ndx
}

# Updates the specified module manifest with a new version number.
# Note: We do NOT use Update-ModuleManifest, because it rewrites the
#       file in a manner that wipes out custom comments.
#       !! RELIES ON EACH PROPERTY BEING DEFINED ON ITS OWN LINE.
function update-ModuleManifestVersion {
  param(
    [Parameter(Mandatory)]
    [Alias('Path')]
    [string] $LiteralPath
    ,
    [Parameter(Mandatory)]
    [Alias('ModuleVersion')]
    [semver] $Version
  )

  $lines = Get-Content -LiteralPath $LiteralPath

  $lines -replace '^(\s*ModuleVersion\s*=).*', ('$1 ''{0}''' -f $Version) | Set-Content -Encoding ascii $LiteralPath
}

function get-settings {
  if (-not (Test-Path $p_configPsdFile)) {
    Write-Warning "Settings file not found: $p_configPsdFile"
    @{}
  } else {
    Import-PowerShellDataFile -LiteralPath $p_configPsdFile
  }
}

function get-NuGetApiKey {
  param(
    [switch] $Prompt
  )
  
  $htConfig = get-settings
  
  if ($Prompt -or -not $htConfig.NuGetApiKey) {
    $configPsdFile = $p_configPsdFile
    # e.g. 5ecf36c5-437f-0123-7654-c91df8f79ca4
    $regex = '^[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}$'
    while ($true) {
      $nuGetApiKey = (Read-Host -Prompt "Enter your NuGet API Key (will be saved in '$configPsdFile')").Trim()
      if ($nuGetApiKey -match $regex) { break }
      Write-Warning "Invalid key specified; a vaid key must match regex '$regex'. Please try again."
    }

    # Update the settings file.
    if (-not (Test-Path -LiteralPath $configPsdFile)) { # create 
@"
<#
  Global configuration file for PowerShell module projects created with New-ModuleProject

  IMPORTANT: 
    * Keep each entry on its own line.
    * Save this file as BOM-less UTF-8 or ASCII and use only ASCII characters.

#>
@{
  NuGetApiKey = '$nuGetApiKey'
}
"@ | Set-Content -Encoding Ascii -LiteralPath $configPsdFile
    } else { # update
      $lines = Get-Content -LiteralPath $configPsdFile

      $lines -replace '^(\s*NuGetApiKey\s*=).*', ('$1 ''{0}''' -f $nuGetApiKey) | Set-Content -Encoding ascii $configPsdFile
          
    }

    $htConfig.NuGetApiKey = $nuGetApiKey
  }

  $htConfig.NuGetApiKey
}

#endregion
