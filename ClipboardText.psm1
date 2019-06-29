<#

IMPORTANT: THIS MODULE MUST REMAIN PSv2-COMPATIBLE.

#>

# Module-wide defaults.

# !! PSv2: We do not even activate the check for accessing nonexistent variables, because
# !!       of a pitfall where parameter variables belonging to a parameter set
# !!       other than the one selected by a given invocation are considered undefined.
if ($PSVersionTable.PSVersion.Major -gt 2) {
  Set-StrictMode -Version 1
}

#region == ALIASES
Set-Alias scbt Set-ClipboardText
Set-Alias gcbt Get-ClipboardText
#endregion

#region == Exported functions

function Get-ClipboardText {
<#
.SYNOPSIS
Gets text from the clipboard.

.DESCRIPTION
Retrieves text from the system clipboard as an arry of lines (by default)
or as-is (with -Raw).

If the clipboard is empty or contains no text, $null is returned.

LINUX CAVEAT: The xclip utility must be installed; on Debian-based platforms
              such as Ubuntu, install it with: sudo apt install xclip

.PARAMETER Raw
Output the retrieved text as-is, even if it spans multiple lines.
By default, if the retrieved text is a multi-line string, each line is 
output individually.

.NOTES
This function is a "polyfill" to make up for the lack of built-in clipboard
support in Windows Powershell v5.0- and in PowerShell Core as of v6.1, 
albeit only with respect to text.

In Windows PowerShell v5+, you can use the built-in Get-Clipboard cmdlet
instead (which this function invokes, if available).

In earlier versions, a helper type is compiled on demand that uses the
Windows API. Note that this means the first invocation of this function
in a given session will be noticeably slower, due to the on-demand compilation.

.EXAMPLE
Get-ClipboardText | ForEach-Object { $i=0 } { '#{0}: {1}' -f (++$i), $_ }

Retrieves text from the clipboard and sends its lines individually through
the pipeline, using a ForEach-Object command to prefix each line with its
line number.

.EXAMPLE
Get-ClipboardText -Raw > out.txt

Retrieves text from the clipboard as-is and saves it to file out.txt
(with a newline appended).
#>
  
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [switch] $Raw
  )

  $rawText = $lines = $null
  # *Windows PowerShell* v5+ in *STA* COM threading mode (which is the default, but it can be started with -MTA)
  if ((test-WindowsPowerShell) -and $PSVersionTable.PSVersion.Major -ge 5 -and 'STA' -eq [threading.thread]::CurrentThread.ApartmentState.ToString()) { 

    Write-Verbose "Windows (PSv5+ in STA mode): deferring to Get-Clipboard"
    if ($Raw) {
      $rawText = Get-Clipboard -Format Text -Raw
    } else {
      $lines = Get-Clipboard -Format Text
    }

  } else {  # Windows PowerShell v4- and/or in MTA threading mode, PowerShell *Core* on any supported platform.

    # No native PS support for writing to the clipboard or native support not available due to MTA mode -> external utilities
    # must be used.
    # (Note: Attempts to use [System.Windows.Forms] proved to be brittle in MTA mode, causing intermittent failures.)
    # Since PS automatically splits external-program output into individual
    # lines and trailing empty lines can get lost in the process, we 
    # must, unfortunately, send the text to a temporary *file* and read
    # that.

    $isWin = $env:OS -eq 'Windows_NT' # Note: $IsWindows is only available in PS *Core*.

    if ($isWin) {

      Write-Verbose "Windows: using WinAPI via helper type"

      # Note: Originally we used a WSH-based solution a la http://stackoverflow.com/a/15747067/45375,
      #       but WSH may be blocked on some systems for security reasons.
      add-WinApiHelperType

      $rawText = [net.same2u.util.Clipboard]::GetText()

    } else {

      $tempFile = [io.path]::GetTempFileName()

      try {

        # Note: For security reasons, we want to make sure it is the actual standard
        #       shell we're invoking on each platform, so we use its full path.
        #       Similarly, for clipboard utilities that are standard on a given platform,
        #       we use their full paths.
        #       Mocking executables invoked by their full paths isn't directly supported
        #       in Pester, so we use helper function invoke-Utility, which *can* be mocked.
        
        if ($IsMacOS) {

          Write-Verbose "macOS: using pbpaste"

          invoke-Utility /bin/sh -c "/usr/bin/pbpaste > '$tempFile'"

        } else { # $IsLinux

          Write-Verbose "Linux: using xclip"

          # Note: Requires xclip, which is not installed by default on most Linux distros
          #       and works with freedesktop.org-compliant, X11 desktops.
          #       Note: Since xclip is not an in-box utility, we make no assumptions 
          #             about its specific location and rely on it to be in $env:PATH.
          invoke-Utility /bin/sh -c "xclip -selection clipboard -out > '$tempFile'"
          # Check for the specific exit code that indicates that `xclip` wasn't found and provide an installation hint.
          if ($LASTEXITCODE -eq 127) { new-StatementTerminatingError "xclip is not installed; please install it via your platform's package manager; e.g., on Debian-based distros such as Ubuntu: sudo apt install xclip" }

        }
        
        if ($LASTEXITCODE) { new-StatementTerminatingError "Invoking the native clipboard utility failed unexpectedly." }

        # Read the contents of the temp. file into a string variable.
        # Temp. file is UTF8, which is the default encoding
        $rawText = [IO.File]::ReadAllText($tempFile)

      } finally {
        Remove-Item $tempFile
      }
    } # -not $isWin
  }

  # Output the retrieved text
  if ($Raw) {  # as-is (potentially multi-line)
    $result = $rawText
  } else {     # as an array of lines (as the PsWinV5+ Get-Clipboard cmdlet does)
    if ($null -eq $lines) {
      # Note: This returns [string[]] rather than [object[]], but that should be fine.
      $lines = $rawText -split '\r?\n'
    }
    $result = $lines
  }

  # If the effective result is the *empty string* [wrapped in a single-element array], we output 
  # $null, because that's what the PsWinV5+ Get-Clipboard cmdlet does.
  if (-not $result) {
    # !! To be consistent with Get-Clipboard, we output $null even in the absence of -Raw,
    # !! even though you could argue that *nothing* should be output (i.e., implicitly, the "arry-valued null", 
    # !! [System.Management.Automation.Internal.AutomationNull]::Value)
    # !! so that trying to *enumerate* the result sends nothing through the pipeline.
    # !! (A similar, but opposite inconsistency is that Get-Content with a zero-byte file outputs the "array-valued null"
    # !!  both with and without -Raw).
    $null
  } else {
    $result
  }

}
  
function Set-ClipboardText {
<#
.SYNOPSIS
Copies text to the clipboard.

.DESCRIPTION
Copies a text representation of the input to the system clipboard.

Input can be provided via the pipeline or via the -InputObject parameter.

If you provide no input, the empty string, or $null, the clipboard is
effectively cleared.

Non-text input is formatted the same way as it would print to the console,
which means that the console/terminal window's [buffer] width determines
the output line width, which may result in truncated data (indicated with
"...").
To avoid that, you can increase the max. line width with -Width, but see 
the caveats in the parameter description.

LINUX CAVEAT: The xclip utility must be installed; on Debian-based platforms
              such as Ubuntu, install it with: sudo apt install xclip

.PARAMETER Width
For non-text input, determines the maximum output-line length.
The default is Out-String's default, which is the current console/terminal
window's [buffer] width.

Be careful with high values and avoid [int]::MaxValue, however, because in
the case of (implicit) Format-Table output each output line is padded to 
that very width, which can require a lot of memory.

.PARAMETER PassThru
In addition to copying the resulting string representation of the input to
the clipboard, also outputs it, as single string.

.NOTES
This function is a "polyfill" to make up for the lack of built-in clipboard
support in Windows Powershell v5.0- and in PowerShell Core as of v6.1,
albeit only with respect to text.
In Windows PowerShell v5.1+, you can use the built-in Set-Clipboard cmdlet
instead (which this function invokes, if available).

.EXAMPLE
Set-ClipboardText "Text to copy"

Copies the specified text to the clipboard.

.EXAMPLE
Get-ChildItem -File -Name | Set-ClipboardText

Copies the names of all files the current directory to the clipboard.

.EXAMPLE
Get-ChildItem | Set-ClipboardText -Width 500

Copies the text representations of the output from Get-ChildItem to the
clipboard, ensuring that output lines are 500 characters wide.
#>
  
  [CmdletBinding(DefaultParameterSetName='Default')] # !! PSv2 doesn't support PositionalBinding=$False
  [OutputType([string], ParameterSetName='PassThru')]
  param(
      [Parameter(Position=0, ValueFromPipeline = $True)] # Note: The built-in PsWinV5.0+ Set-Clipboard cmdlet does NOT have mandatory input, in which case the clipbard is effectively *cleared*.
      [AllowNull()] # Note: The built-in PsWinV5.0+ Set-Clipboard cmdlet allows $null too.
      $InputObject
      ,
      [int] $Width # max. output-line width for non-string input
      ,
      [Parameter(ParameterSetName='PassThru')]
      [switch] $PassThru
  )

  begin {
    # Initialize an array to collect all input objects in.
    # !! Incredibly, in PSv2 using either System.Collections.Generic.List[object] or
    # !! System.Collections.ArrayList ultimately results in different ... | Out-String
    # !! output, with the group header ('Directory:') for input `GetItem / | Out-String`
    # !! inexplicably missing - even .ToArray() conversion or an [object[]] cast
    # !! before piping to Out-String doesn't help.
    # !! Given that we don't expect large collections to be sent to the clipboard,
    # !! we make do with inefficiently "growing" an *array* ([object[]]), i.e.
    # !! cloning the old array for each input object.
    $inputObjs = @()
  }

  process {
    # Collect the input objects.
    $inputObjs += $InputObject
  }
  
  end {

    # * The input as a whole is converted to a a single string with
    #   Out-String, which formats objects the same way you would see on the
    #   console.
    # * Since Out-String invariably appends a trailing newline, we must remove it.
    #   (The PS Core v6 -NoNewline switch is NOT an option, as it also doesn't
    #   place newlines *between* objects.)
    $widthParamIfAny = if ($PSBoundParameters.ContainsKey('Width')) { @{ Width = $Width } } else { @{} }
    $allText = ($inputObjs | Out-String @widthParamIfAny) -replace '\r?\n\z'

    # *Windows PowerShell* v5+ in *STA* COM threading mode (which is the default, but it can be started with -MTA)
    if ((test-WindowsPowerShell) -and $PSVersionTable.PSVersion.Major -ge 5 -and 'STA' -eq [threading.thread]::CurrentThread.ApartmentState.ToString()) { 
        
      # !! As of PsWinV5.1, `Set-Clipboard ''` reports a spurious error (but still manages to effectively) clear the clipboard.
      # !! By contrast, using `Set-Clipboard $null` succeeds.
      Set-Clipboard -Value ($allText, $null)[$allText.Length -eq 0]
      
    } else { # Windows PowerShell v4- and/or in MTA threading mode, PowerShell *Core* on any supported platform.
      
      # No native PS support for writing to the clipboard or native support not available due to MTA mode ->
      # external utilities must be used.
      # (Note: Attempts to use [System.Windows.Forms] proved to be brittle in MTA mode, causing intermittent failures.)

      $isWin = $env:OS -eq 'Windows_NT' # Note: $IsWindows is only available in PS *Core*.

      # To prevent adding a trailing \n, which PS inevitably adds when sending
      # a string through the pipeline to an external command, use a temp. file,
      # whose content can be provided via native input redirection (<)
      $tmpFile = [io.path]::GetTempFileName()

      if ($isWin) {
        # The clip.exe utility requires *BOM-less* UTF16-LE for full Unicode support.
        [IO.File]::WriteAllText($tmpFile, $allText, (New-Object System.Text.UnicodeEncoding $False, $False))
      } else { # $IsUnix -> use BOM-less UTF8
        # PowerShell's UTF8 encoding invariably creates a file WITH BOM
        # so we use the .NET Framework, whose default is BOM-*less* UTF8.
        [IO.File]::WriteAllText($tmpFile, $allText)
      }
      
      # Feed the contents of the temporary file via stdin to the 
      # platform-appropriate clipboard utility.
      try {

        # Note: For security reasons, we want to make sure it is the actual standard
        #       shell we're invoking on each platform, so we use its full path.
        #       Similarly, for clipboard utilities that are standard on a given platform,
        #       we use their full paths.
        #       Mocking executables invoked by their full paths isn't directly supported
        #       in Pester, so we use helper function invoke-Utility, which *can* be mocked.
  
        if ($isWin) {

          Write-Verbose "Windows: using clip.exe"

          # !! Temporary switch to the system drive (a drive guaranteed to be local) so as to 
          # !! prevent cmd.exe from issuing a warning if a UNC path happens to be the current location
          # !! - see https://github.com/mklement0/ClipboardText/issues/4
          Push-Location -LiteralPath $env:SystemRoot
            invoke-Utility "$env:SystemRoot\System32\cmd.exe" /c "$env:SystemRoot\System32\clip.exe" '<' $tmpFile
          Pop-Location

        } elseif ($IsMacOS) {

          Write-Verbose "macOS: using pbcopy"

          invoke-Utility /bin/sh -c "/usr/bin/pbcopy < '$tmpFile'"

        } else { # $IsLinux

          Write-Verbose "Linux: using xclip"
          # Note: Since xclip is not an in-box utility, we make no assumptions 
          #       about its specific location and rely on it to be in $env:PATH.
          # !! >&- (i.e., closing stdout) is necessary, because xclip hangs if you try to redirect its - nonexistent output with `-in`, which also happens impliclity via `$null = ...` in the context of Pester tests.          
          invoke-Utility /bin/sh -c "xclip -selection clipboard -in < '$tmpFile' >&-"

          # Check for the specific exit code that indicates that `xclip` wasn't found and provide an installation hint.
          if ($LASTEXITCODE -eq 127) { new-StatementTerminatingError "xclip is not installed; please install it via your platform's package manager; e.g., on Debian-based distros such as Ubuntu: sudo apt install xclip" }

        }
        
        if ($LASTEXITCODE) { new-StatementTerminatingError "Invoking the platform-specific clipboard utility failed unexpectedly." }

      } finally {
        Pop-Location # Restore the previously current location.
        Remove-Item $tmpFile
      }

    }

    if ($PassThru) {
      $allText
    }

  }

}

#endregion

#region == Private helper functions
  
# Throw a statement-terminating error (instantly exits the calling function and its enclosing statement).
function new-StatementTerminatingError([string] $Message, [System.Management.Automation.ErrorCategory] $Category = 'InvalidOperation') {
    $PSCmdlet.ThrowTerminatingError((New-Object System.Management.Automation.ErrorRecord `
      $Message,
      $null, # a custom error ID (string)
      $Category, # the PS error category - do NOT use NotSpecified - see below.
      $null # the target object (what object the error relates to)
    )) 
}

# Determine if we're runnning in Windows PowerShell.
function test-WindowsPowerShell {
  # !! $IsCoreCLR is not available in Windows PowerShell and, if
  # !! Set-StrictMode is set, trying to access it would fail.
  $null, 'Desktop' -contains $PSVersionTable.PSEdition 
}

# Helper function for invoking an external utility (executable).
# The raison d'être for this function is so that calls to utilities called 
# with their *full paths* can be mocked in Pester.
function invoke-Utility {
  param(
    [Parameter(Mandatory=$true)]
    [string] $LiteralPath,
    [Parameter(ValueFromRemainingArguments=$true)]
    $PassThruArgs
  )
  & $LiteralPath $PassThruArgs
}


# Adds helper type [net.same2u.util.Clipboard] for clipboard access via the 
# Windows API.
# Note: It is fine to blindly call this function repeatedly - after the initial
#       performance hit due to compilation, subsequent invocations are very fast.
function add-WinApiHelperType {
  Add-Type -Name Clipboard -Namespace net.same2u.util -MemberDefinition @'
  [DllImport("user32.dll", SetLastError=true)]
  static extern bool OpenClipboard(IntPtr hWndNewOwner);
  [DllImport("user32.dll", SetLastError = true)]
  static extern IntPtr GetClipboardData(uint uFormat);
  [DllImport("user32.dll", SetLastError=true)]
  static extern bool CloseClipboard();
  
  public static string GetText() {
    string txt = null;
    if (!OpenClipboard(IntPtr.Zero)) { throw new Exception("Failed to open clipboard."); }
    IntPtr handle = GetClipboardData(13); // CF_UnicodeText
    if (handle != IntPtr.Zero) { // if no handle is returned, assume that no text was on the clipboard.
      txt = Marshal.PtrToStringAuto(handle);
    }
    if (!CloseClipboard()) { throw new Exception("Failed to close clipboard."); }
    return txt;
  }
'@
}

#endregion
