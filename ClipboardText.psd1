# Module manifest - save as BOM-less UTF-8 and USE ONLY ASCII CHARACTER IN THIS FILE
@{

# Script module or binary module file associated with this manifest.
# 'ModuleToProcess' has been renamed to 'RootModule', but older PS versions still require the old name.
ModuleToProcess = 'ClipboardText.psm1'

ScriptsToProcess = 'CheckPrereqs.ps1'

# Version number of this module.
ModuleVersion = '0.1.6'

# Supported PSEditions
# !! This keys is not supported in older PS versions.
# CompatiblePSEditions = 'Core', 'Desktop'

# ID used to uniquely identify this module
GUID = '74a03733-2ae5-4f26-ac06-f2939e1a79f9'

# Author of this module
Author = 'Michael Klement <mklement0@gmail.com>'

# Copyright statement for this module
Copyright = '(c) 2018 Michael Klement <mklement0@gmail.com>, released under the [MIT license](http://opensource.org/licenses/MIT)'

# Description of the functionality provided by this module
Description = 'Support for text-based clipboard operations for PowerShell Core (cross-platform) and older versions of Windows PowerShell'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '2.0'

# Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
FunctionsToExport = 'Set-ClipboardText', 'Get-ClipboardText'
# Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
AliasesToExport = 'scbt', 'gcbt'

# Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
PrivateData = @{

    PSData = @{

        # Tags applied to this module. These help with module discovery in online galleries.
        Tags = 'clipboard','text','cross-platform'

        # A URL to the license for this module.
        LicenseUri = 'https://github.com/mklement0/ClipboardText/blob/master/LICENSE.md'

        # A URL to the main website for this project.
        ProjectUri = 'https://github.com/mklement0/ClipboardText'

        # ReleaseNotes of this module - point this to the changelog section of the read-me
        ReleaseNotes = 'https://github.com/mklement0/ClipboardText/blob/master/CHANGELOG.md'

    } # End of PSData hashtable

} # End of PrivateData hashtable

}
