<# Note: 
   * Make sure this file is saved as *UT8 with BOM*, so that
     literal non-ASCII characters are interpreted correctly.

   * When run in WinPSv3+, an attempt is made to run the tests in WinPSv2
     too, but note that requires prior installation of v2 support.
     Also, in PSv2, Pester must be loaded *manually*, via the *full
     path to its *.psd1 file* (seemingly, v2 doesn't find modules located in
     \<version>\ subdirs.).
     For interactive use, the simplest approach is to invoke v2 as follows:
        powershell.exe -version 2 -Command "Import-Module '$((Get-Module Pester).Path)'
#>

# Abort on all unhandled errors.
$ErrorActionPreference = 'Stop'

# PSv2 compatibility: makes sure that $PSScriptRoot reflects this script's folder.
if (-not $PSScriptRoot) { $PSScriptRoot = $MyInvocation.MyCommand.Path } 

# Turn on the latest strict mode, so as to make sure that the ScriptsToProcess
# script that runs the prerequisites-check script dot-sourced also works
# properly when the caller happens to run with Set-StrictMode -Version Latest
# in effect.
Set-StrictMode -Version Latest

# Make sure that any loaded module by the same name is first unloaded
# and then force-load the enclosing module.
Remove-Module -ErrorAction SilentlyContinue ([IO.Path]::GetFileName($PSScriptRoot))
# !! In PSv2, this statement causes Pester to run all tests TWICE (?!)
Import-Module $PSScriptRoot -Force

# Use the platform-appropiate newline.
$nl = [Environment]::NewLine

# See if we're running on *Windows PowerShell*
$isWinPs = $null, 'Desktop' -contains $PSVersionTable.PSEdition


Describe StringInputTest {
  It "Copies and pastes a string correctly." {
    $string = "Here at $(Get-Date)"
    Set-ClipboardText $string
    Get-ClipboardText | Should -BeExactly $string
  }
  It "Correctly round-trips non-ASCII characters." {
    $string = 'Thomas Hübl''s talk about 中文'
    $string | Set-ClipboardText
    Get-ClipboardText | Should -BeExactly $string
  }
  It "Outputs an array of lines by default" {
    $lines = 'one', 'two'
    $string = $lines -join [Environment]::NewLine
    Set-ClipboardText $string
    Get-ClipboardText | Should -BeExactly $lines
  }
  It "Retrieves a multi-line string as-is with -Raw and doesn't append an extra newline." {
    "2 lines${nl}with 1 trailing newline${nl}" | Set-ClipboardText 
    Get-ClipboardText -Raw | Should -Not -Match '(\r?\n){2}\z'
  }
}

Describe EmptyTests {
  BeforeEach {
    'dummy' | Set-ClipboardText # make sure we start with a nonempty clipboard so we can verify that clearing is effective
  }
  It "Not providing input effectively clears the clipboard." {
    Set-ClipboardText # no input
    $null -eq (Get-ClipboardText -Raw) | Should -BeTrue
  }
  It "Passing the empty string effectively clears the clipboard." {
    Set-ClipboardText -InputObject ''  # Note The PsWinV5+ Set-Clipboard reports a spurious error with '', which we mask behind the scenes.
    $null -eq (Get-ClipboardText -Raw) | Should -BeTrue
  }
  It "Passing `$null effectively clears the clipboard." {
    Set-ClipboardText -InputObject $null
    $null -eq (Get-ClipboardText -Raw) | Should -BeTrue
  }
}

Describe PassThruTest {
  It "Set-ClipboardText -PassThru also outputs the text." {
    $in = "line 1${nl}line 2"
    $out = $in | Set-ClipboardText -PassThru
    Get-ClipboardText -Raw | Should -BeExactly $in
    $out | Should -BeExactly $in
  }
}

Describe CommandInputTest {
  It "Copies and pastes a PowerShell command's output correctly" {
    Get-Item / | Set-ClipboardText
    # Note: Inside Set-ClipboardText we remove the trailing newline that 
    #       Out-String invariably adds, so we must do the same here.
    $shouldBe = (Get-Item / | Out-String) -replace '\r?\n\z'
    $pasted = Get-ClipboardText -Raw
    $pasted | Should -BeExactly $shouldBe
  }
  It "Copies and pastes an external program's output correctly" {    
    # Note: whoami without argument works on all supported platforms.
    whoami | Set-ClipboardText
    $shouldBe = whoami
    $is = Get-ClipboardText
    $is | Should -Be $shouldBe
  }
}

Describe OutputWidthTest {
  BeforeAll {
    # A custom object that is implicitly formatted with Format-Table with
    # 2 columns.
    $obj = [pscustomobject] @{ one = '1' * 40; two = '2' * 216 }
  }
  It "Truncates lines that are too wide for the specified width" {
    $obj | Set-ClipboardText -Width 80
    # Note: [3] - the *4th* line - is the line with the two column values in all editions.
    #       [-2] to use the penultimate line is NOT reliable, as the editions differ in
    #       the number of trailing newlines.
    (Get-ClipboardText)[3] | Should -Match '(\.\.\.|…)$' # Note: At some point, PS Core started using the '…' (horizontal ellipsis) Unicode char. instead of three periods.
  }
  It "Allows incrementing the width to accommodate wider lines" {
    $obj | Set-ClipboardText -Width 257 # 40 + 1 (space between columns) + 216
    (Get-ClipboardText)[3].TrimEnd() | Should -BeLikeExactly '*2'
  }
}

# Note: These tests apply to PS *Core* only, because Windows PowerShell doesn't require external utilities for clipboard support.
Describe MissingExternalUtilityTest {

  # We skip these tests in *Windows PowerShell*, because Windows Powershell 
  # does't require external utilities for access to the clipboard.
  # Note: We don't exit right away, because do want to invoke the `It` block
  # with `-Skip` set to $True, so that the results indicated that the test
  # was deliberately skipped.
  if (-not $isWinPs) {

    # Determine the name of the module being tested.
    # For a Mock to be effective in the target module's context, it must be 
    # defined with -ModuleName <name>.
    $thisModuleName = (Split-Path -Leaf $PSScriptRoot)
  
    # Define the platform-appropiate mocks for calling the external clipboard
    # utilities.
    # Note: Since mocking by full executable path isn't supported, we use
    #       helper function invoke-External.

    # macOS, Linux:
    Mock invoke-External -ParameterFilter { $LiteralPath -eq '/bin/sh' } { 
      /bin/sh -c 'nosuchexe' 
    } -ModuleName $thisModuleName

    # Windows:
    Mock invoke-External -ParameterFilter { $LiteralPath -eq "$env:SystemRoot\System32\cmd.exe" } { 
      & "$env:SystemRoot\System32\cmd.exe" /c 'nosuchexe' 
    } -ModuleName $thisModuleName

  }

  It "PS Core: Generates a statement-terminating error when the required external utility is not present" -Skip:$isWinPs {
    { 'dummy' | Set-ClipboardText 2>$null } | Should -Throw
  }

}

Describe MTAtests {
  # Windows PowerShell:
  #  A WinForms text-box workaround is needed when PowerShell is running in COM MTA
  #  (multi-threaded apartment) mode.
  #  By default, v2 runs in MTA mode and v3+ in STA mode.
  #  However, you can *opt into* MTA mode in v3+, and the workaround is then needed too.
  #  (In PSCore on Windows, MTA is the default again, but it has no access to WinForms
  #   anyway and uses external utility clip.exe instead.)
  It "Windows PowerShell: Works in MTA mode" -Skip:(-not $isWinPs -or $PSVersionTable.PSVersion.Major -eq 2) {
    # Recursively invokes the 'StringInputTest' tests.
    # !! This produces NO OUTPUT; to troubleshoot, run the command interactively from the project folder.
    # !! As of Windows PowerShell v5.1.18362.145 on Microsoft Windows 10 Pro (64-bit; Version 1903, OS Build: 18362.175), 
    # !! `Get-Command -Name Add-Member, Get-ChildItem` must be executed BEFORE invoking Pester; without it, 
    # !! Pester inexplicably fails to locate these commands during module import and cannot be loaded.
    powershell.exe -noprofile -MTA -Command "if ([threading.thread]::CurrentThread.ApartmentState.ToString() -ne 'MTA') { Throw "Not in MTA mode." }; Get-Command -Name Add-Member, Get-ChildItem; Invoke-Pester -Name StringInputTest -EnableExit"
    $LASTEXITCODE | Should -Be 0
  }
}

Describe v2Tests {
  # Invoke these tests in *WinPS v2*, which amounts to a RECURSION.
  # Therefore, EXECUTION TAKES A WHILE.
  It "Windows PowerShell: Passes all tests in v2 as well." -Skip:(-not $isWinPs -or $PSVersionTable.PSVersion.Major -eq 2) {
    # !! An Install-Module-installed Pester is located in a version-named subfolder, which v2 cannot 
    # !! detect, so we import Pester by explicit path.
    # !! Also `-version 2` must be the *first* argument passed to `powershell.exe`.
    #
    # !! NO OUTPUT IS PRODUCED - to troubleshoot, run the command interactively from the project folder.
    # !! Notably, *prior installation of v2 support is needed*, and PowerShell seems to quietly ignore `-version 2`
    # !! in its absence, so we have to test from *within* the session.
    powershell.exe -version 2 -noprofile  -Command "Set-StrictMode -Version Latest; Import-Module '$((Get-Module Pester).Path)'; if (`$PSVersionTable.PSVersion.Major -ne 2) { Throw 'v2 SUPPORT IS NOT INSTALLED.' }; Invoke-Pester"
    $LASTEXITCODE | Should -Be 0
  }
}
