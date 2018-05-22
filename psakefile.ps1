properties {
  # Supported parameters (pass with -parameter @{ <name> = <value>[; ...] }):
  #
  #   SkipTest[s] / NoTest[s] ... [Boolean]; if $True, skips execution of tests
  #   Force / Yes ... [Boolean]; skips confirmation prompts
  #
  $p_SkipTests = $SkipTests -or $SkipTest -or $NoTests -or $NoTest
  $p_SkipPrompts = $Force -or $Yes
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
        [pscustomobject] @{ Name = $name; Alias = $alias; Description = $val }
      }
    }
  } | Out-String | Write-Host -ForegroundColor Green
}

task Push -depends Test -description 'Commits changes and pushes them to GitHub.' {

  assert-WsCleanOrNoUntrackedFiles

}

task Test -alias t -description 'Invoke Pester to run all tests.' {
  
  if ($p_SkipTests) { Write-Verbose -Verbose 'Skipping tests, as requested.'; return }
  
  Assert ((Invoke-Pester -PassThru).FailedCount -eq 0) "Aborting, because at least one test failed."

}

task Publish -alias pub -depends _assertMasterBranch, _assertNoUntrackedFiles, Test, Commit -description 'Publish to the PowerShell Gallery.' {
}

task LocalPublish -alias lpub -depends _assertMasterBranch, _assertNoUntrackedFiles, Test, Commit -description 'Publish locally, to the current-user module location.' {

  $targetParentPath = if ($env:MK_UTIL_FOLDER_PERSONAL) {
    "$env:MK_UTIL_FOLDER_PERSONAL/Settings/PowerShell/Modules"
  } else {
    if ($env:OS -eq 'Windows_NT') { "$HOME\Documents\{0}\Modules" -f ('WindowsPowerShell', 'PowerShell')[[bool]$IsCoreClr] } else { "$HOME/.local/share/powershell/Modules" }
  }

  # Make sure the user confirms the intent.
  assert-confirmed @"
  About to publish to:

    $targetParentPath
  
  which will replace any existing version, if present.
    
  Proceed?
"@

  $ErrorActionPreference = 'Stop'

  $targetPath = Join-Path $targetParentPath (Split-Path -Leaf $PWD.Path)

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

task Commit -depends _assertNoUntrackedFiles {

  if ((iu git status --porcelain).count -eq 0) {
    Write-Verbose -Verbose '(Nothing to commit.)'
  } else {
    Write-Verbose -Verbose "Committing changes to branch '$(iu git symbolic-ref --short HEAD)'; please provide a commit message..."
    iu git add --update .
    iu git commit
  }

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

Bump the version number
"@ -Choices $choices

    Assert ($ndx -ne $choices.count -1) 'Aborted by user request.'
    if ($ndx -eq $choices.count -2) {
      Write-Warning "Retaining existing version $ver, as requested."
      $verNew = $ver
      break
    } else {
        wv -v $choices[$ndx]
        $verNew = increment-version $ver -Property $choices[$ndx]    
        $ndx = read-HostChoice @"
About to bump version number:
      
        $ver -> $verNew
      
Proceed?
"@ -Choice 'Yes', 'Revise'
      if ($ndx -eq 0) { 
        break
      }
    }
  }

  if ($ver -ne $verNew) {
    update-ModuleManifestVersion -Path $psdFile -ModuleVersion $verNew
  }

}

#region == Internal helper tasks.

# Playground task for quick experimentation
task pg -depends Commit {
  'after'
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

#endregion
