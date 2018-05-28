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

  $p_ModuleName = Split-Path -Leaf $PSScriptRoot
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

task UpdateChangeLog -description "Ensure that the change-log covers the current verion." {

  ensure-ChangeLogHasEntryTemplate -LiteralPath ./CHANGELOG.md -Version (get-ThisModuleVersion)

  if (test-ChangeLogHasUninstantiatedTemplates -LiteralPath ./CHANGELOG.md) {
    Write-Verbose -Verbose "Opening ./CHANGELOG for editing to ensure that version to be released is covered by an entry..."
    edit-Sync ./CHANGELOG.md
  }

  # Make sure that 
  assert-ChangeLogHasNoUninstantiatedTemplates -LiteralPath ./CHANGELOG.md

}

task Publish -alias pub -depends _assertMasterBranch, _assertNoUntrackedFiles, Test, Version, UpdateChangeLog, Commit -description 'Publish to the PowerShell Gallery.' {

  $moduleVersion = get-ThisModuleVersion

  Write-Verbose -Verbose 'Creating and pushing tags...'
  # Create a tag for the new version
  iu git tag -f -a -m "Version $moduleVersion" "v$moduleVersion"
  # Update the generic 'pre'[release] and 'stable' tags to point to the same tag, as appropriate.
  # !! As of PowerShell Core v6.1.0-preview.2, PowerShell module manifests only support [version] instances
  # !! and therefore do not support prereleases. 
  # ?? However, Publish-Module does have an -AllowPrerelease switch - but it's undocumented as of 22 May 2018.
  iu git tag -f ('stable', 'pre')[[bool] $moduleVersion.PreReleaseLabel]

  # Push the tags to the origin repo.
  iu git push -f origin master --tags

  assert-confirmed @"
About to PUBLISH TO THE POWERSHELL GALLERY:

  Module:  $p_moduleName
  Version: $moduleVersion
  
  IMPORTANT: Make sure that:
    * you've run ```Invoke-psake LocalPublish`` to publish the module locally.
    * you've waited for the changes to replicate to all VMs.
    * you've run ``Push-Location (Split-Path (Get-Module -ListAvailable $p_moduleName).Path); if (`$?) { Invoke-Pester }``
      and verified that the TESTS PASS:
       * on ALL PLATFORMS and
       * on WINDOWS, both in PowerShell Core and Windows PowerShell

Proceed?
"@

  # Copy the module to a TEMPORARY FOLDER for publishing, so that 
  # the .git folder and other files not relevant at runtime can be EXCLUDED.
  # A feature request to have Publish-Module support exclusions directly is
  # pending - see https://github.com/PowerShell/PowerShellGet/issues/191
  $tempPublishDir = Join-Path ([io.Path]::GetTempPath()) "${PID}/${moduleName}"
  New-Item -ItemType Directory -Path $tempPublishDir

  copy-forPublishing -LiteralPath $tempPublishDir

  try {
    # Note: -Repository PSGallery is implied.
    Publish-Module -Path $tempPublishDir -NuGetApiKey (get-NuGetApiKey)
  } finally {
push-location $tempPublishDir #???
#???    Remove-Item -Force -Recurse -LiteralPath $tempPublishDir
  }

  Write-Verbose -Verbose @"
Publishing succeeded. 
Note that it can take a few minutes for the new module [version] to appear in the gallery.

URL: https://www.powershellgallery.com/packages/$p_moduleName"
"@

}

task LocalPublish -alias lpub -depends Test -description 'Publish locally, to the current-user module location.' {

  $targetParentPath = if ($env:MK_UTIL_FOLDER_PERSONAL) {
    "$env:MK_UTIL_FOLDER_PERSONAL/Settings/PowerShell/Modules"
  } else {
    if ($env:OS -eq 'Windows_NT') { "$HOME\Documents\{0}\Modules" -f ('WindowsPowerShell', 'PowerShell')[[bool]$IsCoreClr] } else { "$HOME/.local/share/powershell/Modules" }
  }
  
  $targetPath = Join-Path $targetParentPath (Split-Path -Leaf $PSScriptRoot)

  # Make sure the user confirms the intent.
  assert-confirmed @"
About to PUBLISH LOCALLY to:

  $targetPath

which will REPLACE the existing folder's content, if present.
  
Proceed?
"@

  copy-forPublishing -LiteralPath $targetPath

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

task Version -alias ver -description 'Show or bump the module''s version number.' {

  $psdFile = Resolve-Path ./*.psd1
  $htModuleMetaData = Import-PowerShellDataFile -LiteralPath $psdFile
  $ver = [version] $htModuleMetaData.ModuleVersion

  # Prompt for what version-number component should be incremented.
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
      # Confirm the resulting new version.
      $verNew = increment-version $ver -Property $choices[$ndx]    
      $ndx = read-HostChoice @"
  About to bump to NEW VERSION NUMBER:
        
          $ver -> $verNew
        
  Proceed?
"@ -Choice 'Yes', 'Revise' -DefaultChoiceIndex 0
      if ($ndx -eq 0) { 
        break
      }
    }

  }

  # Update the module manifest with the new version number.
  if ($ver -ne $verNew) {
    update-ModuleManifestVersion -Path $psdFile -ModuleVersion $verNew
  }

  # Add an entry *template* for the new version to the changelog file.
  ensure-ChangeLogHasEntryTemplate -LiteralPath ./CHANGELOG.md -Version $verNew

}

task EditConfig -alias edc -description "Open the global configuration file for editing." {  
  Invoke-Item -LiteralPath $p_configPsdFile
}

task EditManifest -alias edm -description "Open the module manifest for editing." {  
  Invoke-Item -LiteralPath "$PSScriptRoot/$(Split-Path -Leaf $PSScriptRoot).psd1"
}

task EditPsakeFile -alias edp -description "Open the psakefile for editing." {  
  Invoke-Item -LiteralPath $PSCommandPath
}

#region == Internal helper tasks.

# # Playground task for quick experimentation
task _pg  {
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
# Outputs an inremented [semver] or [version] instance.
# If -Property is not specified, the patch / build level is incremented.
# If the input version is not already a [version] or [semver] version,
# [semver] is assumed, EXCEPT when:
#   * [semver] is not available (WinPS up to at least v5.1)
#   * a -Property name is passed that implies [version], namely 'Build' or 'Revision'.
# Examples:
#   increment-version 1.2.3 -Property Minor # -> [semver] '1.3.3'
#   increment-version 1.2.3 -Property Revision # -> [version] '1.2.3.1'
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
  
  # If the version is passed as a string and property names specific to [version]
  # are used, assume [version]
  if ($Property -in 'Build', 'Revision') { $AssumeLegacyVersion = $True }

  # See if [semver] is supported in the host PS version (not in WinPS as of v5.1).
  $isSemVerSupported = [bool] $(try { [semver] } catch {})

  if ($isSemVerSupported -and $Version -is [semver]) {
    $verObj = $Version
  } elseif ($Version -is [version]) {
    $verObj = $Version    
  } else {
    $verObj = $null
    if ($isSemVerSupported -and -not $AssumeLegacyVersion) {
       $null = [semver]::TryParse([string] $Version, [ref] $verObj)
    }
    if (-not $verObj -and -not ([version]::TryParse([string] $Version, [ref] $verObj))) {
      Throw "Could not parse as a version: '$Version'"
    }
  }

  $arguments = 
    ($verObj.Major, ($verObj.Major + 1))[$Property -eq 'Major'],
    ($verObj.Minor, ($verObj.Minor + 1))[$Property -eq 'Minor']
    
  if ($isSemVerSupported -and $verObj -is [semver]) {

    if ($Property -eq 'Revision') { Throw "[semver] versions do not have a '$Property' property." }
    # Allow interchangeable use of 'Build' and 'Patch' to refer to the 3rd component.
    if ($Property -eq 'Build') { $Property = 'Patch' }
      
    $arguments += ($verObj.Patch, ($verObj.Patch + 1))[$Property -eq 'Patch']

  } else { # [version]

    # Allow interchangeable use of 'Build' and 'Patch' to refer to the 3rd component.
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
      [int] $DefaultChoiceIndex = -1, # LAST option is the default choice.
      [switch] $NoDefault # no default; i.e., disallow empty/blank input
    )

    if ($DefaultChoiceIndex -eq -1) { $DefaultChoiceIndex = $Choices.Count - 1 }

    $choiceCharDict = [ordered] @{}
    foreach ($choice in $Choices) {
      $choiceChar = if ($choice -cmatch '\p{Lu}') { $matches[0] } else { $choice[0] }
      if ($choiceCharDict.Contains($choiceChar)) { Throw "Choices are ambiguous; make sure that each initial char. or the first uppercase char. is unique: $Choices" }
      $choiceCharDict[$choiceChar] = $null
    }
    [string[]] $choiceChars = $choiceCharDict.Keys

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
    [version] $Version
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

# Copy this project's file for publishing to the specified dir., excluding dev-only files.
function copy-forPublishing {
  param(
    [Parameter(Mandatory)]
    [string] $LiteralPath
  )

  # Create the target folder or, if it already exists, remove its *contents*.
  if (Test-Path -LiteralPath $LiteralPath) {
    Remove-Item -Force -Recurse -Path $LiteralPath/*
  } else {
    New-Item -ItemType Directory -Path $LiteralPath
  }

  # Copy this folder's contents recursively, but exclude the .git subfolder, the .gitignore file, and the psake "make file".
  Copy-Item -Recurse -Path "$($PSScriptRoot)/*" -Destination $LiteralPath -Exclude '.git', '.gitignore', 'psakefile.ps1'
  
  Write-Verbose -Verbose "'$($PSScriptRoot)' copied to '$LiteralPath'"
  
}

# Ensure the presence of an entry *template* for the specified version in the specified changelog file.
function ensure-ChangeLogHasEntryTemplate {
  param(
    [parameter(Mandatory=$True)] [string] $LiteralPath,
    [parameter(Mandatory=$True)] [version] $Version
    )
  $content = Get-Content -Raw $LiteralPath
  if ($content -match [regex]::Escape("* **v$Version**")) {
    Write-Verbose "Changelog entry for $Version is already present in $LiteralPath"
  } else {
    Write-Verbose "Adding changelog entry for $Version to $LiteralPath"
    $parts = $content -split '(<!-- RETAIN THIS COMMENT.*?-->)'
    if ($parts.Count -ne 3) { Throw 'Cannot find (single) marker comment in $LiteralPath' }
    $newContent = $parts[0] + $parts[1] + "`n`n* **v$Version** ($([datetime]::now.ToString('yyyy-MM-dd'))):`n  * [???] " + $parts[2]
    # Update the input file.
    # Note: We write the file as BOM-less UTF-8.    
    [IO.File]::WriteAllText((Convert-Path -LiteralPath $LiteralPath), $newContent)
  }
  # Indicate whether the file had to be updated.
}

function test-ChangeLogHasUninstantiatedTemplates {
  param(
    [parameter(Mandatory=$True)] [string] $LiteralPath
  )
  $content = Get-Content -Raw $LiteralPath
  $content -match [regex]::Escape('???')
}

function assert-ChangeLogHasNoUninstantiatedTemplates {
  param(
    [parameter(Mandatory=$True)] [string] $LiteralPath
  )
  $content = Get-Content -Raw $LiteralPath
  Assert (-not (test-ChangeLogHasUninstantiatedTemplates -LiteralPath $LiteralPath)) "Aborting, because $LiteralPath still contains placeholders in lieu of real information."
}

# Retrieves this module's version number from the module manifest as a [version] instance.
function get-ThisModuleVersion {
  [version] (Import-PowerShellDataFile "${PSScriptRoot}/${p_moduleName}.psd1").ModuleVersion
}

# Synchronously open the specified file(s) for editing.
function edit-Sync {
  [CmdletBinding(DefaultParameterSetName='Path')]
  param(
    [Parameter(ParameterSetName='Path', Mandatory=$True, Position=0)] [SupportsWildcards()] [string[]] $Path,
    [Parameter(ParameterSetName='LiteralPath', Mandatory=$True, Position=0)] [string[]] $LiteralPath
  )

  if ($Path) {
    $paths = Resolve-Path -EA Stop -Path $Path
  } else {
    $paths = Resolve-Path -EA Stop -LiteralPath $LiteralPath
  }

  # Editor executables in order of preference.
  # Use the first one found to be installed.
  $edExes = 'code', 'atom', 'subl', 'gedit', 'vim', 'vi'  # code == VSCode
  $edExe = foreach ($exe in $edExes) {
    if (Get-Command -ErrorAction Ignore $exe) { $exe; break }
  }
  # If no suitable editor was found and when running on Windows,
  # see if vim.exe, installed with Git but not in $env:PATH, can be located.
  if (-not $edExe -and ($env:OS -ne 'Windows_NT' -or -not (Test-Path ($edExe = "$env:PROGRAMFILES/Git/usr/bin/vim.exe")))) {
    Throw "No suitable text editor for synchronous editing found."
  }

  # For VSCode, Atom, SublimeText, ensure synchronous execution in a new window.
  # For gedit and vim / vi that is the befault behavior, so no options needed.
  $opts = @()
  if ($edExe -in 'code', 'atom', 'subl') {
    $opts = '--new-window', '--wait'
  }

  # Invoke the editor synchronously.
  & $edExe $opts $paths

}

#endregion
