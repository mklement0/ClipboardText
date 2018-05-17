<!-- Remove, once published/released. -->
![project status - not ready for release](https://img.shields.io/badge/status-not_ready_for_release-red.svg)

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/mklement0/ClipboardText/blob/master/LICENSE.md)

<!-- START doctoc -->
<!-- END doctoc -->

# ClipboardText: Clipboard text support for PowerShell Core (cross-platform) and Windows PowerShell v2-v4

`ClipboardText` is a **cross-edition, cross-platform PowerShell module** that provides support
for **copying text to and retrieving text from the system clipboard**, via the `Set-ClipboardText` and `Get-ClipboardText` cmdlets.

It is useful in **two basic scenarios**:

* Use with PowerShell _Core_ on (hopefully) all supported platforms.
   * As of v6.1, PowerShell Core doesn't ship with clipboard cmdlets.
   * This module fills this gap, albeit only with respect to _text_.  
   * The implementation relies on external utilities (command-line programs) on all supported platforms:
      * Windows: `clip.exe` (built in)
      * macOS: `pbcopy` and `pbpaste` (built in)
      * Linux: [`xclip`](https://github.com/astrand/xclip) (_requires installation_ via the system's package manager; e.g. `sudo apt-get install xclip`; available on X11-based [freedesktop.org](https://www.freedesktop.org/wiki/)-compliant desktops, such as on Ubuntu)

* Use with _older versions_ of _Windows PowerShell_.

  * Since v5.0, Windows PowerShell ships with `Set-Clipboard` and `Get-Clipboard` cmdlets.
  * This module fills this gap for v2-v4, albeit only with respect to _text_.  
  * For implementing backward-compatible functionality, you may also use this module in v5+, in which case this module's cmdlets call the built-in ones behind the scenes.
  * On older versions, the implementation uses [Windows Forms](https://en.wikipedia.org/wiki/Windows_Forms) .NET types behind the scenes (namespace `System.Windows.Forms`)

# Installation

## Manual Installation

* Clone this repository (as a subfolder) into one of the directories listed in the `$env:PSModulePath` variable; e.g., to install the module in the context of the current user, choose the following parent folders:
  * **Windows**: 
     * Windows PowerShell: `$HOME\Documents\WindowsPowerShell\Modules`
     * PowerShell Core `$HOME\Documents\PowerShell\Modules`
  * **macOs, Linux** (PowerShell Core): 
    * `~/.local/share/powershell/Modules`

As long as you've cloned into one of the directories listed in the `$env:PSModulePath` variable - copying to some of which requires elevation / `sudo` - and as long your `$PSModuleAutoLoadingPreference` is not set (the default) or set to `All`, calling `Set-ClipboardText` or `Get-ClipboardText` should import the module on demand.

To explicitly impot the module, run `Import-Module <path/to/module-folder>`.

# Usage

In short:

* `Set-ClipboardText` copies strings as-is; output from commands is copied using the same representation you see in the console, essentially obtained via `Out-String`; e.g.:

```powershell
# Copy the full path of the current filesystem location to the clipbard:
$PWD.Path | Set-ClipboardText

# Copy the names of all files in the current directory to the clipboard:
Get-ChildItem -File -Name | Set-ClipboardText
```


* `Get-ClipboardText` retrieves text from the clipboard as an _array of lines_ by default; use `-Raw` to request the text as-is, as a potentially multi-line string.

```powershell
# Retrieve text from the clipboard as a single string and save it to a file:
Get-ClipboardText -Raw > out.txt

# Retrieve text from the clipboard as an array of lines and prefix each with
# a line number:
Get-ClipboardText | ForEach-Object { $i=0 } { '#{0}: {1}' -f (++$i), $_ }
```



For more, consult the **built-in help** after installation:

```powershell
# Concise command-line help with terse description and syntax diagram.
Get-ClipboardText -?
Set-ClipboardText -?

# Full help, including parameter descriptions and details and examples.
Get-Help -Full Get-ClipboardText
Get-Help -Full Set-ClipboardText

# Examples only
Get-Help -Examples Get-ClipboardText
Get-Help -Examples Set-ClipboardText
```

# License

See [LICENSE.md](./LICENSE.md).

# Changelog

See [CHANGELOG.md](./CHANGELOG.md).
