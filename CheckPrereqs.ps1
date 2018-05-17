# Checks whether all prerequisites for using this modules are met.

# If running on Linux and CLI `xclip` is not availble (via $PATH),
# issue a warning with installation instructions.
if (
  -not $IsLinux <# on Windows and macOS we know that the required libraries / CLIs are present #> `
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
