<#

IMPORTANT: THIS MODULE MUST REMAIN PSv2-COMPATIBLE.

#>

# Module-wide defaults.

# !! PSv2: We dectivate even the check for accessing nonexistent variables, because
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
In Windows PowerShell v5.1+, you can use the built-in Get-Clipboard cmdlet
instead (which this function invokes, if available).

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
  if (test-WindowsPowerShell) { # *Windows PowerShell*

    # Determine this thread's COM threading model, because the clipboard-access method
    # must be chosen accordingly.
    $isSTA = [threading.thread]::CurrentThread.ApartmentState.ToString() -eq 'STA'

    if ($PSVersionTable.PSVersion.Major -ge 5 -and $isSTA) { # Ps*Win* v5+ has Get-Clipboard / Set-Clipboard cmdlets, but they too require STA mode.
      
      if ($Raw) {
        $rawText = Get-Clipboard -Format Text -Raw
      } else {
        $lines = Get-Clipboard -Format Text
      }

    } else { # WinPSv4- or WinPSv5+ explicitly started with the -MTA switch

      Add-Type -AssemblyName System.Windows.Forms
      if ($isSTA) {
          # -- STA mode:
          Write-Verbose "STA mode: Using [Windows.Forms.Clipboard] directly."
          # To be safe, we explicitly specify that Unicode (UTF-16) be used - older platforms may default to ANSI.
          $rawText = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
      } else { # $isMTA
          # -- MTA mode: Since the clipboard must be accessed in STA mode, we use a [System.Windows.Forms.TextBox] instance to mediate.
          Write-Verbose "MTA mode: Using a [System.Windows.Forms.TextBox] instance for clipboard access."
          $tb = New-Object System.Windows.Forms.TextBox
          $tb.Multiline = $True
          $tb.Paste()
          $rawText = $tb.Text
      }

    }

  } else {  # PowerShell *Core*

    # No native PS support for writing to the clipboard -> external utilities
    # must be used.
    # Since PS automatically splits external-program output into individual
    # lines and trailing empty lines can get lost in the process, we 
    # must, unfortunately, send the text to a temporary *file* and read
    # that.

    $tempFile = [io.path]::GetTempFileName()

    try {
      
      if ($IsWindows) {
        # Use an ad-hoc JScript to access the clipboard.
        # Gratefully adapted from http://stackoverflow.com/a/15747067/45375
        # Note that trying the following directly from PowerShell Core does NOT work,
        #   (New-Object -ComObject htmlfile).parentWindow.clipboardData.getData('text')
        # because .parentWindow is always $null in *older* PS versions, e.g. in v2.
        # Passing true as the last argument to .CreateTextFile() creates a UTF16-LE file (with BOM).
        $tempScript = [io.path]::GetTempFileName()
        @"
var txt = WSH.CreateObject('htmlfile').parentWindow.clipboardData.getData('text'); 
var f = WSH.CreateObject('Scripting.FileSystemObject').CreateTextFile('$($tempFile -replace "\\", "\\")', true, true);
f.Write(txt); f.Close();
"@ | Set-content -Encoding ASCII -LiteralPath $tempScript
        cscript /nologo /e:JScript $tempScript
        Remove-Item $tempScript
      } elseif ($IsMacOS) {

        # Note: For full robustness, using the full path to sh, '/bin/sh' is preferable, but then 
        #       we couldn't use mock functions to override the command for testing.
        sh -c "pbpaste > '$tempFile'"

      } else { # $IsLinux

        # Note: Requires xclip, which is not installed by default on most Linux distros
        #       and works with freedesktop.org-compliant, X11 desktops.
        sh -c "xclip -selection clipboard -out > '$tempFile'"
        if ($LASTEXITCODE -eq 127) { new-StatementTerminatingError "xclip is not installed; please install it via your platform's package manager; e.g., on Debian-based distros such as Ubuntu: sudo apt install xclip" }

      }
      
      if ($LASTEXITCODE) { new-StatementTerminatingError "Invoking the native clipboard utility failed unexpectedly." }

      # Read the contents of the temp. file into a string variable.
      if ($IsWindows) { # temp. file is UTF16-LE 
        $rawText = [IO.File]::ReadAllText($tempFile, [Text.Encoding]::Unicode)
      } else { # temp. file is UTF8, which is the default encoding
        $rawText = [IO.File]::ReadAllText($tempFile)
      }

    } finally {
      Remove-Item $tempFile
    }

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
    # !! even though you could argue that *nothing* should be output (i.e., implicitly, the "null collection", 
    # !! [System.Management.Automation.Internal.AutomationNull]::Value)
    # !! so that trying to *enumerate* the result sends nothing through the pipeline.
    # !! (A similar, but opposite inconsistency is that Get-Content with a zero-byte file outputs the "null collection"
    # !!  both with and withour -Raw).
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

WINDOWS CAVEAT: In MTA mode, passing an empty string is not supported; 
                a newline will be copied instead, and a warning issued.

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

    if (test-WindowsPowerShell) { # *Windows PowerShell*
        
        # Determine this thread's COM threading model, because the clipboard-access method
        # must be chosen accordingly.
        $isSTA = [threading.thread]::CurrentThread.ApartmentState.ToString() -eq 'STA'

        if ($PSVersionTable.PSVersion.Major -ge 5 -and $isSTA) { # Ps*Win* v5+ has Get-Clipboard / Set-Clipboard cmdlets, but they too require STA mode.
          
          # !! As of PsWinV5.1, `Set-Clipboard ''` reports a spurious error (but still manages to effectively) clear the clipboard.
          # !! By contrast, using `Set-Clipboard $null` succeeds.
          Set-Clipboard -Value ($allText, $null)[$allText.Length -eq 0]
          
        } else { # WinPSv4- or WinPSv5+ explicitly started with the -MTA switch
          
          Add-Type -AssemblyName System.Windows.Forms
          if ($isSTA) {
              # -- STA mode: we can use [Windows.Forms.Clipboard] directly.
              Write-Verbose "STA mode: Using [Windows.Forms.Clipboard] directly."
              if ($allText.Length -eq 0) { $AllText = "`0" } # Strangely, SetText() breaks with an empty string, claiming $null was passed -> use a null char.
              # To be safe, we explicitly specify that Unicode (UTF-16) be used - older platforms may default to ANSI.
              [System.Windows.Forms.Clipboard]::SetText($allText, [System.Windows.Forms.TextDataFormat]::UnicodeText)

          } else { # $isMTA
              # -- MTA mode: Since the clipboard must be accessed in STA mode, we use a [System.Windows.Forms.TextBox] instance to mediate.
              if ($allText.Length -eq 0) {
                # !! The [System.Windows.Forms.TextBox] approach cannot be used set the clipboard to an empty string, because a text box must
                # !! must be *non-empty* in order to copy something. Hence we use clip.exe
                Write-Verbose "MTA mode: Using clip.exe rather than a [System.Windows.Forms.TextBox] instance, because the empty string is to be copied."
                $null | clip.exe
                if ($LASTEXITCODE) { new-StatementTerminatingError 'Invoking clip.exe with $null input failed unexpectedly.' }
              } else {
                Write-Verbose "MTA mode: Using a [System.Windows.Forms.TextBox] instance for clipboard access."
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Multiline = $True
                $tb.Text = $allText
                $tb.SelectAll()
                $tb.Copy()
              }
          }

      }
      
    } else { # PowerShell *Core*
      
      # No native PS support for writing to the clipboard ->
      # external utilities must be used.

      # To prevent adding a trailing \n, which PS inevitably adds when sending
      # a string through the pipeline to an external command, use a temp. file,
      # whose content can be provided via native input redirection (<)
      $tmpFile = [io.path]::GetTempFileName()

      if ($IsWindows) {
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

        if ($IsWindows) {
          Write-Verbose "Windows: using clip.exe"
          cmd.exe /c clip.exe '<' $tmpFile  # !! Invoke `cmd` as `cmd.exe` so as to support Pester-based `Mock`s - at least as of v4.3.1, that's a requirement; see https://github.com/pester/Pester/issues/1043
        } elseif ($IsMacOS) {
          Write-Verbose "macOS: Using pbcopy"
          sh -c "pbcopy < '$tmpFile'"
        } else { # $IsLinux
          Write-Verbose "Linux: using xclip"
          sh -c "xclip -selection clipboard -in < '$tmpFile' >&-" # !! >&- (i.e., closing stdout) is necessary, because xclip hangs if you try to redirect its - nonexistent output with `-in`, which also happens impliclity via `$null = ...` in the context of Pester tests.
          if ($LASTEXITCODE -eq 127) { new-StatementTerminatingError "xclip is not installed; please install it via your platform's package manager; e.g., on Debian-based distros such as Ubuntu: sudo apt install xclip" }
        }
        
        if ($LASTEXITCODE) { new-StatementTerminatingError "Invoking the platform-specific clipboard utility failed unexpectedly." }

      } finally {
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

#endregion
