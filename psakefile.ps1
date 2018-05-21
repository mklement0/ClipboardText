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

task Publish -alias pub -depends _assertMasterBranch, _assertWsCleanOrNoUntrackedFiles, Test -description 'Publish to the PowerShell Gallery.' {
}

task LocalPublish -alias lpub -depends _assertMasterBranch, _assertWsCleanOrNoUntrackedFiles, Test -description 'Publish locally, to the current-user module location.' {

  $targetParentPath = if ($env:MK_UTIL_FOLDER_PERSONAL) {
    "$env:MK_UTIL_FOLDER_PERSONAL/Settings/PowerShell/Modules"
  } else {
    if ($env:OS -eq 'Windows_NT') { "$HOME\Documents\{0}\Modules" -f ('WindowsPowerShell', 'PowerShell')[[bool]$IsCoreClr] } else { "$HOME/.local/share/powershell/Modules" }
  }

  # Make sure the user confirms the intent.
  assert-confirmed "About to publish to '$targetParentPath', which will replace any existing version, if present.`nContinue?"

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


task pg -depends _commit {
  'after'
}

#region == Internal helper tasks.

task _commit -depends _assertWsCleanOrNoUntrackedFiles {

  iu git add --update .

}

task _assertMasterBranch {
  Assert -conditionToCheck ((git symbolic-ref --short HEAD) -eq 'master') -failureMessage "Must be on branch 'master'"
}

task _assertWsCleanOrNoUntrackedFiles {
  Assert (-not ((git status --porcelain) -like '`?`? *')) 'Workspace must not contain untracked files.'
}


#endregion

#region == Internal elper functions

# Helper function to prompt the user for confirmation, unless bypassed.
function assert-confirmed {
  param(
    [parameter(Mandatory)]
    [string] $Message,
    [string] $Caption
  )

  if ($p_SkipPrompts) { Write-Verbose -Verbose 'Bypassing confirmation prompts, as requested.'; return }

  Assert $PSCmdlet.ShouldContinue($Message, $Caption) 'Aborted by user request.'
  
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

#endregion