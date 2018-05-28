# Note: By default, psake behaves as if $ErrorActionPreference = 'Stop' had been set.
#       I.e., *any* PS errors - even nonterminating ones - abort execution by default.

properties {

  $thisModuleName = Split-Path -Leaf $PSScriptRoot
  # A single hashtable for all script-level properies.
  $props = @{

    # == Properties derived from optional parameters (passed with -parameter @{ ... })
    # ?? Is there a way we can query all parameters passed so we can error out
    # ?? on detecting unknown ones?
    # Supported parameters (pass with -parameter @{ <name> = <value>[; ...] }):
    #
    #   SkipTest[s] / NoTest[s] ... [Boolean]; if $True, skips execution of tests
    #   Force / Yes ... [Boolean]; skips confirmation prompts
    #
    SkipTests = $SkipTests -or $SkipTest -or $NoTests -or $NoTest
    SkipPrompts = $Force -or $Yes

    # == Internally used / derived properties.
    ModuleName = $thisModuleName
    Files = @{
      GlobalConfig = "$HOME/.new-moduleproject.config.psd1"
      Manifest = "$thisModuleName.psd1"
      ChangeLog = "$PSScriptRoot/CHANGELOG.md"
      ReadMe = "$PSScriptRoot/README.md"
      License = "$PSScriptRoot/LICENSE.md"
    }

  } # $props
}


# If no task is passed, list all defined (public) tasks. 
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

task Test -alias t -description 'Run all tests via Pester.' {
  
  if ($props.SkipTests) { Write-Verbose -Verbose 'Skipping tests, as requested.'; return }
  
  Assert ((Invoke-Pester -PassThru).FailedCount -eq 0) "Aborting, because at least one test failed."

}

task UpdateChangeLog -description "Ensure that the change-log covers the current version." {

  $changeLogFile = $props.Files.Changelog

  # Ensure that an entry for the (new) version exists in the change-log file.
  # If not present, add an entry *template*, containing a *placeholder*.
  ensure-ChangeLogHasEntryTemplate -Version (get-ThisModuleVersion)

  if (test-StillHasPlaceholders -LiteralPath $changeLogFile) {
    # Synchronously prompt to replace the placeholder with real information.
    Write-Verbose -Verbose "Opening $changeLogFile for editing to ensure that version to be released is covered by an entry..."
    edit-Sync $changeLogFile
  }

  # Make sure that all placeholders were actually replaced with real information.
  assert-HasNoPlaceholders -LiteralPath $changeLogFile

}

task Publish -alias pub -depends _assertMasterBranch, _assertNoUntrackedFiles, Test, Version, UpdateChangeLog -description 'Publish to the PowerShell Gallery.' {

  $moduleVersion = get-ThisModuleVersion

  Write-Verbose -Verbose 'Committing...'
  # Use the change-log entry for the new version as the commit message.
  iu git add --update .
  iu git commit -m (get-ChangeLogEntry -Version $moduleVersion)

  # Note: 
  # We could try to assert up front that the version to be published has a higher number than
  # the currently published one, with `(Find-Module $props.ModuleName).Version`.
  # It can be a tad slow, however. For now we rely on Publish-Module to fail if the condition 
  # is not met. (Does it fail with a meaningful error message?)

  Write-Verbose -Verbose 'Creating and pushing tags...'
  # Create a tag for the new version
  iu git tag -f -a -m "Version $moduleVersion" "v$moduleVersion"
  # Update the generic 'pre'[release] and 'stable' tags to point to the same tag, as appropriate.
  # !! As of PowerShell Core v6.1.0-preview.2, PowerShell module manifests only support [version] instances
  # !! and therefore do not support prereleases. 
  # ?? However, Publish-Module does have an -AllowPrerelease switch - but it's undocumented as of 22 May 2018.
  $isPrerelease = $False
  iu git tag -f ('stable', 'pre')[$isPrerelease]

  # Push the tags to the origin repo.
  iu git push -f origin master --tags

  # Final prompt before publishign to the PS gallery.
  assert-confirmed @"

About to PUBLISH TO THE POWERSHELL GALLERY:

  Module:  $($props.moduleName)
  Version: $moduleVersion
  
  IMPORTANT: Make sure that:
    * you've run ``Invoke-psake LocalPublish`` to publish the module locally.
    * you've waited for the changes to replicate to all VMs.
    * you've run ``Push-Location (Split-Path (Get-Module -ListAvailable $($props.moduleName)).Path); if (`$?) { Invoke-Pester }``
      and verified that the TESTS PASS:
       * on ALL PLATFORMS and
       * on WINDOWS, both in PowerShell Core and Windows PowerShell

Proceed?
"@

  # Copy the module to a TEMPORARY FOLDER for publishing, so that 
  # the .git folder and other files not relevant at runtime can be EXCLUDED.
  # A feature request to have Publish-Module support exclusions directly is
  # pending - see https://github.com/PowerShell/PowerShellGet/issues/191
  # IMPORTANT: For publishing to succeed, the temp. dir.'s name must match the module's.
  $tempPublishDir = Join-Path ([io.Path]::GetTempPath()) "$PID/$($props.ModuleName))"
  $null = New-Item -ItemType Directory -Path $tempPublishDir

  copy-forPublishing -DestinationPath $tempPublishDir

  try {
    # Note: -Repository PSGallery is implied.
    Publish-Module -Path $tempPublishDir -NuGetApiKey (get-NuGetApiKey)
  } finally {
    Remove-Item -Force -Recurse -LiteralPath $tempPublishDir
  }

  Write-Verbose -Verbose @"

PUBLISHING SUCCEEDED.

Note that it can take a few minutes for the new module [version] to appear in the gallery.

URL: https://www.powershellgallery.com/packages/$($props.moduleName)"
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

  copy-forPublishing -DestinationPath $targetPath

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

  $htModuleMetaData = Import-PowerShellDataFile -LiteralPath $props.Files.Manifest
  $ver = [version] $htModuleMetaData.ModuleVersion

  Write-Host @"
  
  CURRENT version number:
  
  $ver
"@

  if (-not $props.SkipPrompts) {

    # Prompt for what version-number component should be incremented.
    $choices = 'Major', 'mInor', 'Patch', 'Retain', 'Abort'
    while ($True) {
  
      $ndx = read-HostChoice @"
  
  BUMP THE VERSION NUMBER
"@ -Choices $choices
  
      Assert ($ndx -ne $choices.count -1) 'Aborted by user request.'
      if ($ndx -eq $choices.count -2) {
        Write-Warning "Retaining existing version $ver, as requested."
        $verNew = $ver
        break
      } else {
        # Prompt to confirm the resulting new version.
        $verNew = increment-version $ver -Property $choices[$ndx]    
        $ndx = read-HostChoice @"
    Confirm the NEW VERSION NUMBER:
          
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
      update-ModuleManifestVersion -Path $props.Files.Manifest -ModuleVersion $verNew
    }

    # Add an entry *template* for the new version to the changelog file.
    ensure-ChangeLogHasEntryTemplate -Version $verNew

  }

}

task EditConfig -alias edc -description "Open the global configuration file for editing." {  
  Invoke-Item -LiteralPath $props.Files.GlobalConfig
}

task EditManifest -alias edm -description "Open the module manifest for editing." {  
  Invoke-Item -LiteralPath $props.Files.Manifest
}

task EditPsakeFile -alias edp -description "Open this psakefile for editing." {  
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

  if ($props.SkipPrompts) { Write-Verbose -Verbose 'Bypassing confirmation prompts, as requested.'; return }

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

# Reads the global config (settings) and returns the settings as a hashtable.
# Note: Analogous to use in Git, "global" refers to *current-user-global* settings.
function get-GlobalConfig {
  if (-not (Test-Path $props.Files.globalConfig)) {
    Write-Warning "No global settings filefound: $($props.Files.GlobalConfig)"
    @{}
  } else {
    Import-PowerShellDataFile -LiteralPath $props.Files.globalConfig
  }
}

function get-NuGetApiKey {
  param(
    [switch] $Prompt
  )

  # Read the user's global configuration.
  $htConfig = get-GlobalConfig
  
  if ($Prompt -or -not $htConfig.NuGetApiKey) {

    # Prompt the user.
    $configPsdFile = $props.Files.globalConfig
    # e.g. 5ecf36c5-437f-0123-7654-c91df8f79ca4
    $regex = '^[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}$'
    while ($true) {
      $nuGetApiKey = (Read-Host -Prompt "Enter your NuGet API Key (will be saved in '$configPsdFile')").Trim()
      if ($nuGetApiKey -match $regex) { break }
      Write-Warning "Invalid key specified; a vaid key must match regex '$regex'. Please try again."
    }

    # Update  or create the config file.
    if (-not (Test-Path -LiteralPath $configPsdFile)) { # create on demand.
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
  } # if

  # Outptut the key.
  $htConfig.NuGetApiKey
}

# Copy this project's file for publishing to the specified dir., excluding dev-only files.
function copy-forPublishing {
  param(
    [Parameter(Mandatory)]
    [string] $DestinationPath
  )

  # Create the target folder or, if it already exists, remove its *contents*.
  if (Test-Path -LiteralPath $DestinationPath) {
    Remove-Item -Force -Recurse -Path $DestinationPath/*
  } else {
    New-Item -ItemType Directory -Path $DestinationPath
  }

  # Copy this folder's contents recursively, but exclude the .git subfolder, the .gitignore file, and the psakefile.
  Copy-Item -Recurse -Path "$($PSScriptRoot)/*" -Destination $DestinationPath -Exclude '.git', '.gitignore', 'psakefile.ps1'
  
  Write-Verbose -Verbose "'$PSScriptRoot' copied to '$DestinationPath'"
  
}

# Ensure the presence of an entry *template* for the specified version in the specified changelog file.
function ensure-ChangeLogHasEntryTemplate {

  param(
    [parameter(Mandatory)] [version] $Version
  )

  $changeLogFile = $props.Files.ChangeLog
  $content = Get-Content -Raw -LiteralPath $changeLogFile
  if ($content -match [regex]::Escape("* **v$Version**")) {
    Write-Verbose "Changelog entry for $Version is already present in $changeLogFile"
  } else {
    Write-Verbose "Adding changelog entry for $Version to $changeLogFile"
    $parts = $content -split '(<!-- RETAIN THIS COMMENT.*?-->)'
    if ($parts.Count -ne 3) { Throw 'Cannot find (single) marker comment in $changeLogFile' }
    $newContent = $parts[0] + $parts[1] + "`n`n* **v$Version** ($([datetime]::now.ToString('yyyy-MM-dd'))):`n  * [???] " + $parts[2]
    # Update the input file.
    # Note: We write the file as BOM-less UTF-8.    
    [IO.File]::WriteAllText((Convert-Path -LiteralPath $changeLogFile), $newContent)
  }

}

# Indicates if the specified file (still) contains placeholders (literal '???' sequences).
function test-StillHasPlaceholders {
  param(
    [parameter(Mandatory)] [string] $LiteralPath
  )
  (Get-Content -Raw $LiteralPath) -match [regex]::Escape('???')
}

# Fails, if the specified file (still) contains placeholders.
function assert-HasNoPlaceholders {
  param(
    [Parameter(Mandatory)] [string] $LiteralPath
  )
  Assert (-not (test-StillHasPlaceholders -LiteralPath $LiteralPath)) "Aborting, because $LiteralPath still contains placeholders in lieu of real information."
}

# Retrieves this module's version number from the module manifest as a [version] instance.
function get-ThisModuleVersion {
  [version] (Import-PowerShellDataFile $props.Files.Manifest).ModuleVersion
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

  # RESPECT THE EDITOR CONFIGURED FOR GIT.
  $edCmdLinePrefix = git config core.editor # Note: $LASTEXITCODE will be 1 if no editor is defined.
  # Note: the editor may be defined as an executable *plus options*, such as `code -n -w`.
  $edExe, $edOpts = -split $edCmdLinePrefix
  if (-not $edExe) { # If none is explicitly configured, FALL BACK TO GIT'S DEFAULT.
    # Check env. variables.
    $edExe = foreach ($envVarVal in $env:EDITOR, $env:VISUAL) {
      if ($envVarVal) { $envVarVal; break }
    }
    # Look for gedit, vim, vi
    # Note: Git will only use `gedit` by default if that default is compiled into Git's binary.
    #       This is the case on Ubuntu, for instance.
    #       !! Therefore, it's possible for us to end up using a different editor than Git, such as on Fedora.
    $edExe = foreach ($exe in 'gedit', 'vim', 'vi') {
      if (Get-Command -ErrorAction Ignore $exe) { $exe; break }
    }
    # If no suitable editor was found and when running on Windows,
    # see if vim.exe, installed with Git but not present in $env:PATH, can be located, as a last resort.
    if (-not $edExe -and ($env:OS -ne 'Windows_NT' -or -not (Test-Path ($edExe = "$env:PROGRAMFILES/Git/usr/bin/vim.exe")))) {
      # We give up.
      Throw "No suitable text editor for synchronous editing found."
    }
    # Notify the user that no "friendly" editor is configured.
    # TODO: We could offer to perform this configuration by prompting the user
    #       to choose one of the installed editors, if present.
    Write-Warning @"

NO "FRIENDLY" TEXT EDITOR IS CONFIGURED FOR GIT.

To define one, use one of the following commands, depending on what's available
on your system:

* Visual Studio Code:

  git config --global core.editor 'code -n -w'
  
* Atom:

  git config --global core.editor 'atom -n -w'

* Sublime Text:

  git config --global core.editor 'subl -n -w'

"@    
  }

  # # Editor executables in order of preference.
  # # Use the first one found to be installed.
  # $edExes = 'code', 'atom', 'subl', 'gedit', 'vim', 'vi'  # code == VSCode
  # $edExe = foreach ($exe in $edExes) {
  #   if (Get-Command -ErrorAction Ignore $exe) { $exe; break }
  # }
  # # If no suitable editor was found and when running on Windows,
  # # see if vim.exe, installed with Git but not in $env:PATH, can be located.
  # if (-not $edExe -and ($env:OS -ne 'Windows_NT' -or -not (Test-Path ($edExe = "$env:PROGRAMFILES/Git/usr/bin/vim.exe")))) {
  #   Throw "No suitable text editor for synchronous editing found."
  # }

  # # For VSCode, Atom, SublimeText, ensure synchronous execution in a new window.
  # # For gedit and vim / vi that is the befault behavior, so no options needed.
  # $opts = @()
  # if ($edExe -in 'code', 'atom', 'subl') {
  #   $opts = '--new-window', '--wait'
  # }

  # Invoke the editor synchronously.
  & $edExe $edOpts $paths

}

# Extracts the change-log entry (multi-line block) for the specified version.
function get-ChangeLogEntry {
  param(
    [Parameter(Mandatory)] [version] $Version
  )
  $changeLogFile = $props.Files.ChangeLog
  $content = Get-Content -Raw -LiteralPath $changeLogFile
  $entriesBlock = ($content -split '<!-- RETAIN THIS COMMENT.*?-->')[-1]
  if ($entriesBlock -notmatch ('(?sm)' + [regex]::Escape("* **v$Version**") + '.+?(?=\r?\n' + [regex]::Escape('* **v') + ')')) {
    Throw "Failed to extract change-long entry for version $version."
  }
  # Output the entry.
  $Matches[0]
}

#endregion
