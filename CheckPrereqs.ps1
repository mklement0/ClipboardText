# Checks whether all prerequisites for using this modules are met.
# IMPORTANT: 
#    Make sure this script runs properly even with Set-StrictMode -Version Latest
#    in effect; notably, make sure all variables accessed have been initialized.

# If running on Linux and CLI `xclip` is not availble (via $PATH),
# issue a warning with installation instructions.
# Note: We must guard against access to potentially undefined variable $IsLinux
#       if the caller's scope happens to have Set-StrictMode -Version 1 or higher in effect.
#       We can't just use Set-StrictMode -Off, because this script is being *dot-sourced*,
#       which would modify the caller's environment. Note that it's safe to use the PSv3+ Ignore value 
#       with -ErrorAction only in the -or clause, because it will only execute on Linux, where it is guaranteed to be supported.
if (
  -not ((Get-Variable -ErrorAction SilentlyContinue IsLinux) -and $IsLinux) <# on Windows and macOS we know that the required libraries / CLIs are present #> `
    -or
  (Get-Command -Type Application -ErrorAction Ignore xclip) <# `xclip` is available #>
) { exit 0 }

Write-Warning @'
Your Linux environment is missing the `xclip` utility, which is required for
the Set-ClipboardText and Get-ClipboardText cmdlets to function.

PLEASE INSTALL `xclip` VIA YOUR PLATFORM'S PACKAGE MANAGER.
E.g., on Debian-based distros such as Ubuntu, run: 

  sudo apt install xclip

'@
