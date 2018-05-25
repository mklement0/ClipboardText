<# Note: 
   * Make sure this file is saved as *UT8 with BOM*, so that
     literal non-ASCII characters are interpreted correctly.

   * To run the tests in PSv2, Pester must be loaded *manually*, via the *full
     path to its *.psd1 file* (seemingly, v2 doesn't find modules located in
     \<version>\ subdirs.); e.g.:

       # NOTE: Adjust path as needed.
       ipmo 'C:\Program Files\WindowsPowerShell\Modules\Pester\4.3.1\Pester.psd1'

       # If you're willing to assume that the last matching file in the following
       # wildcard pattern loads the *most recent* among multiple installed Pester
       # versions:
       ipmo (gi 'C:\Program Files\WindowsPowerShell\Modules\Pester\*\Pester.psd1')[-1]
#>

# PSv2 compatibility: makes sure that $PSScriptRoot reflects this script's folder.
if (-not $PSScriptRoot) { $PSScriptRoot = $MyInvocation.MyCommand.Path } 

# Make sure that the enclosing module is (re)loaded.
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
  # !! In PSv2 (in the default MTA mode), clearing the clipboard (copying an empty string) is not supported.
  # !! We do the next best thing and copy a *newline* instead.
  # !! In PSv3+, Get-ClipboardText should return $null after effectively clearing the clipboard
  # !! (both with and without -Raw, even though without -Raw you could argue that the "null collection" should be output instead).
  $shouldBe = ($null, $nl)[$PSVersionTable.PSVersion.Major -eq 2]
  It "Not providing input effectively clears the clipboard." {
    'dummy' | Set-ClipboardText
    Set-ClipboardText # no input
    $shouldBe -eq (Get-ClipboardText -Raw) | Should -BeTrue
  }
  It "Passing the empty string effectively clears the clipboard." {
    'dummy' | Set-ClipboardText
    Set-ClipboardText -InputObject ''  # Note The PsWinV5+ Set-Clipboard reports a spurious error with '', which we mask.
    $shouldBe -eq (Get-ClipboardText -Raw) | Should -BeTrue
  }
  It "Passing `$null effectively clears the clipboard." {
    'dummy' | Set-ClipboardText
    Set-ClipboardText -InputObject $null
    $shouldBe -eq (Get-ClipboardText -Raw) | Should -BeTrue
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
  It "truncates lines that are too wide for the specified width" {
    $obj | Set-ClipboardText -Width 80
    (Get-ClipboardText)[3] | Should -BeLikeExactly '*...'
  }
  It "allows incrementing the width to accommodate wider lines" {
    $obj | Set-ClipboardText -Width 257 # 40 + 1 (space between columns) + 216
    (Get-ClipboardText)[3].TrimEnd() | Should -BeLikeExactly '*2'
  }
}

# Note: These tests apply to PS *Core* only, because Windows PowerShell doesn't require external utilities for clipboard support.
Describe MissingExternalUtilityTest {

  # See if we're running on *Windows PowerShell*, in which case we skip the
  # tests, because Windows Powershell does't require external utilities for
  # access to the clipboard.
  # $isWinPs = $null, 'Desktop' -contains $PSVersionTable.PSEdition
  # Note: We don't exit right away, because do want to invoke the `It` block
  # with `-Skip` set to $True, so that the results indicated that the test
  # was deliberately skipped.

  if (-not $isWinPs) {

    # Determine the name of the module being tested.
    # For a Mock to be effective in the target module's context, it must be 
    # defined with -ModuleName <name>.
    $thisModuleName = (Split-Path -Leaf $PSScriptRoot)
  
    # Define the platform-appropiate mocks.
    # Note that the conditional Mocks are necessary, because the Mock function
    # requires that the targeted command *exist*.
    if ($env:OS -eq 'Windows_NT') {
      # !! As of Pester v4.3.1, even though the `Mock` is defined "extension-less"
      # !! as `cmd` rather than `cmd.exe`, only `cmd.exe` invocations are covered.
      # !! See https://github.com/pester/Pester/issues/1043
      Mock cmd { & $env:SystemRoot\System32\cmd.exe /c 'nosuchexe' } -ModuleName $thisModuleName
    } else {
      Mock sh  { /bin/sh -c 'nosuchutil' } -ModuleName $thisModuleName
    }

  }

  It "PS Core: Generates a statement-terminating error when the required external utility is not present" -Skip:$isWinPs {
    { 'dummy' | Set-ClipboardText 2>$null } | Should -Throw
  }

}

Describe 'MTA Tests' {
  
  It
}