#Requires -Version 5.1
<#
.SYNOPSIS
    Shell Extension Context Menu Blocker - Modular Edition
    
.DESCRIPTION
    Blocks/unblocks context menu entries from UWP/MSIX applications by managing
    the Shell Extensions Blocked registry key. Designed to be modular and 
    configurable for different applications.
    
.NOTES
    Author:         Context Menu Blocker Project
    Compatibility:  Windows 10 1903+, Windows 11
    
    SAFETY: Blocking these entries only removes context menu items.
    It does NOT affect application functionality, file operations, or system stability.
    
.EXAMPLE
    .\ContextMenuBlocker.ps1
    Runs the interactive menu
    
.EXAMPLE
    .\ContextMenuBlocker.ps1 -BlockAll -NoPrompt
    Blocks all entries without prompts (for automation)

.NOTES
    v1.3 - ASCII fallback: auto-detects raster font, renders clean ASCII if needed
    v1.2 - Encoding fix: all non-ASCII UI chars generated via [char] code points
    v1.1 - Patched exit calls to allow paste-into-console usage
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'BlockAll')]
    [switch]$BlockAll,
    
    [Parameter(ParameterSetName = 'UnblockAll')]
    [switch]$UnblockAll,
    
    [Parameter(ParameterSetName = 'BlockAll')]
    [Parameter(ParameterSetName = 'UnblockAll')]
    [switch]$NoPrompt,
    
    [Parameter(ParameterSetName = 'BlockAll')]
    [Parameter(ParameterSetName = 'UnblockAll')]
    [switch]$NoRestartExplorer
)

#region ========================================================================
#                       BOX-DRAWING CHARACTER TABLE
#  Generated at runtime from Unicode code points so the .ps1 file stays ASCII.
#endregion =====================================================================

# Detect whether the console can render Unicode box-drawing glyphs.
# Raster Fonts (the PS5.1 default) cannot; TrueType fonts (Consolas,
# Lucida Console, Cascadia) can.  We check the console font family
# via P/Invoke -- if unavailable or raster, fall back to ASCII.

$Script:UseUnicode = $true
try {
    $consoleFont = $null
    # Try .NET call available in PS5.1 conhost
    Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetCurrentConsoleFontEx(
    IntPtr hConsoleOutput,
    bool bMaximumWindow,
    ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CONSOLE_FONT_INFOEX {
    public uint cbSize;
    public uint nFont;
    public short dwFontSizeX;
    public short dwFontSizeY;
    public int FontFamily;
    public int FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string FaceName;
}
'@ -Name ConsoleHelper -Namespace Win32 -ErrorAction Stop

    $fontInfo = New-Object Win32.ConsoleHelper+CONSOLE_FONT_INFOEX
    $fontInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($fontInfo)
    $handle = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(0)
    # STD_OUTPUT_HANDLE = -11
    $handle = (Add-Type -MemberDefinition '[DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int nStdHandle);' -Name Kernel32 -Namespace Win32Get -PassThru -ErrorAction Stop)::GetStdHandle(-11)
    $null = [Win32.ConsoleHelper]::GetCurrentConsoleFontEx($handle, $false, [ref]$fontInfo)
    $consoleFont = $fontInfo.FaceName

    # Raster font reports empty or "Terminal"
    if ([string]::IsNullOrWhiteSpace($consoleFont) -or $consoleFont -eq 'Terminal') {
        $Script:UseUnicode = $false
    }
}
catch {
    # If P/Invoke fails (ISE, VS Code terminal, etc.) assume Unicode is fine
    $Script:UseUnicode = $true
}

if ($Script:UseUnicode) {
    $Script:B = @{
        TL  = [string][char]0x2554   # double top-left
        TR  = [string][char]0x2557   # double top-right
        BL  = [string][char]0x255A   # double bottom-left
        BR  = [string][char]0x255D   # double bottom-right
        H   = [string][char]0x2550   # double horizontal
        V   = [string][char]0x2551   # double vertical
        LT  = [string][char]0x2560   # double left-tee
        RT  = [string][char]0x2563   # double right-tee
        sTL = [string][char]0x250C   # single top-left
        sTR = [string][char]0x2510   # single top-right
        sBL = [string][char]0x2514   # single bottom-left
        sBR = [string][char]0x2518   # single bottom-right
        sH  = [string][char]0x2500   # single horizontal
        sV  = [string][char]0x2502   # single vertical
        sLT = [string][char]0x251C   # single left-tee
        sRT = [string][char]0x2524   # single right-tee
        Blk = [string][char]0x25A0   # filled square
        Emp = [string][char]0x25A1   # empty square
        FB  = [string][char]0x2588   # full block
        Arr = [string][char]0x2190   # left arrow
    }
} else {
    $Script:B = @{
        TL  = "+"    # double top-left
        TR  = "+"    # double top-right
        BL  = "+"    # double bottom-left
        BR  = "+"    # double bottom-right
        H   = "="    # double horizontal
        V   = "|"    # double vertical
        LT  = "+"    # double left-tee
        RT  = "+"    # double right-tee
        sTL = "+"    # single top-left
        sTR = "+"    # single top-right
        sBL = "+"    # single bottom-left
        sBR = "+"    # single bottom-right
        sH  = "-"    # single horizontal
        sV  = "|"    # single vertical
        sLT = "+"    # single left-tee
        sRT = "+"    # single right-tee
        Blk = "[X]"  # filled square
        Emp = "[ ]"  # empty square
        FB  = "#"    # full block
        Arr = "<-"   # left arrow
    }
}

#region ========================================================================
#                              CONFIGURATION SECTION
#  Modify these values to target different applications or customize behavior
#endregion =====================================================================

$Script:Config = @{
    # =========================================================================
    # APPLICATION PROFILE
    # =========================================================================
    # To target a DIFFERENT application, modify ONLY this section.
    # Everything below "PATHS" and "BEHAVIOR OPTIONS" is application-agnostic.
    # =========================================================================
    
    # Display name for menus and logs
    AppName = "Dropbox"
    
    # Pattern to match package folders in WindowsApps
    # Use * as wildcard. Example: DropboxInc.Dropbox_VERSION_x64__HASH
    AppPackagePattern = "DropboxInc.Dropbox_*"
    
    # Regex to extract version from folder name
    # Must have capture group 1 containing the version string
    VersionRegex = 'DropboxInc\.Dropbox_([0-9]+(?:\.[0-9]+)*)_'
    
    # Regex to parse verb IDs into human-readable descriptions (optional)
    # Must have capture group 1 containing the command name portion
    # Set to $null to use raw verb IDs as descriptions
    VerbParseRegex = 'Dropbox\d*(.+?)(?:Command)?\d*$'
    
    # -------------------------------------------------------------------------
    # PATHS
    # -------------------------------------------------------------------------
    
    # Base path for WindowsApps (usually don't change)
    WindowsAppsPath = "$env:ProgramFiles\WindowsApps"
    
    # Registry path for blocked shell extensions (don't change)
    BlockedExtensionsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"
    
    # -------------------------------------------------------------------------
    # BEHAVIOR OPTIONS
    # -------------------------------------------------------------------------
    
    # Automatically restart Explorer after changes? (true/false)
    # If false, will prompt user
    AutoRestartExplorer = $false
    
    # Enable logging to file?
    EnableLogging = $true
    
    # Log file path (set to $null to disable file logging)
    LogPath = Join-Path $env:USERPROFILE "ContextMenuBlocker.log"
    
    # Backup directory for state exports
    BackupPath = Join-Path $env:USERPROFILE "ContextMenuBlocker_Backups"
}

#endregion =====================================================================

#region ========================================================================
#                                CORE FUNCTIONS

#endregion =====================================================================

function Write-Log {
    <#
    .SYNOPSIS
        Writes formatted log messages to console and optionally to file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',
        
        [Parameter()]
        [switch]$NoNewline
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$($Level.ToUpper().PadRight(7))] $Message"
    
    $colorMap = @{
        'Info'    = 'White'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
        'Success' = 'Green'
        'Debug'   = 'DarkGray'
    }
    
    $params = @{
        Object = $logEntry
        ForegroundColor = $colorMap[$Level]
    }
    if ($NoNewline) { $params.NoNewline = $true }
    
    Write-Host @params
    
    if ($Script:Config.EnableLogging -and $Script:Config.LogPath) {
        try {
            Add-Content -Path $Script:Config.LogPath -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # Silently ignore logging errors
        }
    }
}

function Test-Administrator {
    <#
    .SYNOPSIS
        Checks if current session has administrator privileges
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevation {
    <#
    .SYNOPSIS
        Relaunches script with administrator privileges if needed
    #>
    if (-not (Test-Administrator)) {
        Write-Log "Administrator privileges required. Elevating..." -Level Warning
        
        # Detect PowerShell host (Core vs Desktop)
        $psHost = if ($PSVersionTable.PSEdition -eq 'Core') { 
            'pwsh.exe' 
        } else { 
            'powershell.exe' 
        }
        
        # Build argument list preserving parameters
        $arguments = @(
            "-NoProfile"
            "-ExecutionPolicy", "Bypass"
            "-File", "`"$PSCommandPath`""
        )
        
        # Preserve command-line parameters
        if ($BlockAll) { $arguments += "-BlockAll" }
        if ($UnblockAll) { $arguments += "-UnblockAll" }
        if ($NoPrompt) { $arguments += "-NoPrompt" }
        if ($NoRestartExplorer) { $arguments += "-NoRestartExplorer" }
        
        try {
            Start-Process $psHost -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
            return
        }
        catch {
            Write-Log "Failed to elevate privileges: $_" -Level Error
            Write-Log "Please run this script as Administrator" -Level Error
            if (-not $NoPrompt) { Read-Host "Press Enter to exit" }
            return
        }
    }
}

function Initialize-Environment {
    <#
    .SYNOPSIS
        Initializes required registry paths and directories
    #>
    
    # Create blocked extensions registry key if missing
    if (-not (Test-Path $Script:Config.BlockedExtensionsPath)) {
        try {
            New-Item -Path $Script:Config.BlockedExtensionsPath -Force | Out-Null
            Write-Log "Created registry key: $($Script:Config.BlockedExtensionsPath)" -Level Success
        }
        catch {
            Write-Log "Failed to create registry key: $_" -Level Error
            return $false
        }
    }
    
    # Create backup directory if logging enabled
    if ($Script:Config.EnableLogging -and $Script:Config.BackupPath) {
        if (-not (Test-Path $Script:Config.BackupPath)) {
            try {
                New-Item -Path $Script:Config.BackupPath -ItemType Directory -Force | Out-Null
            }
            catch {
                Write-Log "Could not create backup directory: $_" -Level Warning
            }
        }
    }
    
    return $true
}

function Get-AppPackageFolders {
    <#
    .SYNOPSIS
        Finds all installed versions of the target application
    .OUTPUTS
        Array of PSCustomObject with package information, sorted by version descending
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()
    
    $basePath = $Script:Config.WindowsAppsPath
    
    if (-not (Test-Path $basePath)) {
        Write-Log "WindowsApps path not found: $basePath" -Level Error
        return @()
    }
    
    $folders = @()
    
    try {
        $candidates = Get-ChildItem -Path $basePath -Directory -ErrorAction Stop | 
            Where-Object { $_.Name -like $Script:Config.AppPackagePattern }
    }
    catch {
        Write-Log "Cannot access WindowsApps: $_" -Level Error
        return @()
    }
    
    foreach ($folder in $candidates) {
        # Extract version using configured regex
        if ($folder.Name -match $Script:Config.VersionRegex) {
            $versionString = $Matches[1]
            
            # Safe version parsing with fallback
            $versionObj = $null
            try {
                $versionObj = [version]$versionString
            }
            catch {
                Write-Log "Non-standard version format: $versionString" -Level Debug
            }
            
            $manifestPath = Join-Path $folder.FullName "AppxManifest.xml"
            
            $folders += [PSCustomObject]@{
                Name         = $folder.Name
                Version      = $versionString
                VersionSort  = if ($versionObj) { $versionObj } else { [version]"0.0.0.0" }
                Path         = $folder.FullName
                LastModified = $folder.LastWriteTime
                ManifestPath = $manifestPath
            }
        }
    }
    
    # Sort by version descending (newest first)
    return @($folders | Sort-Object VersionSort -Descending)
}

function Get-ContextMenuEntries {
    <#
    .SYNOPSIS
        Parses AppxManifest.xml to extract all context menu verb definitions
    .DESCRIPTION
        Properly handles XML namespaces and deduplicates entries by CLSID
    .OUTPUTS
        Array of PSCustomObject with verb information
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )
    
    if (-not (Test-Path $ManifestPath)) {
        Write-Log "Manifest not found: $ManifestPath" -Level Error
        return @()
    }
    
    # Load XML
    try {
        [xml]$manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to parse manifest XML: $_" -Level Error
        return @()
    }
    
    # Set up namespace manager for proper XPath queries
    $nsManager = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $nsManager.AddNamespace("default", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $nsManager.AddNamespace("desktop3", "http://schemas.microsoft.com/appx/manifest/desktop/windows10/3")
    $nsManager.AddNamespace("desktop4", "http://schemas.microsoft.com/appx/manifest/desktop/windows10/4")
    $nsManager.AddNamespace("desktop5", "http://schemas.microsoft.com/appx/manifest/desktop/windows10/5")
    
    # Use hashtable for deduplication by CLSID (case-insensitive)
    $entriesMap = @{}
    
    # ─────────────────────────────────────────────────────────────────────────────
    # Parse CloudFilesContextMenus (desktop3 namespace)
    # These appear only inside the sync folder
    # ─────────────────────────────────────────────────────────────────────────────
    
    $cloudFilesVerbs = $manifest.SelectNodes("//desktop3:CloudFilesContextMenus/desktop3:Verb", $nsManager)
    
    foreach ($verb in $cloudFilesVerbs) {
        $clsid = $verb.GetAttribute("Clsid")
        $verbId = $verb.GetAttribute("Id")
        
        if ($clsid) {
            $clsidKey = $clsid.ToUpper()
            
            if (-not $entriesMap.ContainsKey($clsidKey)) {
                $entriesMap[$clsidKey] = [PSCustomObject]@{
                    Verb        = $verbId
                    Clsid       = $clsid
                    Scope       = "Inside Sync Folder"
                    Category    = "CloudFiles"
                    Description = Get-VerbDescription -VerbId $verbId
                }
            }
        }
    }
    
    # ─────────────────────────────────────────────────────────────────────────────
    # Parse FileExplorerContextMenus (desktop4/desktop5 namespaces)
    # These appear everywhere (all files, folders, background)
    # ─────────────────────────────────────────────────────────────────────────────
    
    foreach ($nsPrefix in @("desktop4", "desktop5")) {
        $verbs = $manifest.SelectNodes("//${nsPrefix}:Verb", $nsManager)
        
        foreach ($verb in $verbs) {
            $clsid = $verb.GetAttribute("Clsid")
            $verbId = $verb.GetAttribute("Id")
            
            if ($clsid) {
                $clsidKey = $clsid.ToUpper()
                
                if (-not $entriesMap.ContainsKey($clsidKey)) {
                    $entriesMap[$clsidKey] = [PSCustomObject]@{
                        Verb        = $verbId
                        Clsid       = $clsid
                        Scope       = "Everywhere"
                        Category    = "FileExplorer"
                        Description = Get-VerbDescription -VerbId $verbId
                    }
                }
            }
        }
    }
    
    # Return sorted by verb name
    return @($entriesMap.Values | Sort-Object Category, Verb)
}

function Get-VerbDescription {
    <#
    .SYNOPSIS
        Returns a human-readable description for known verb IDs
    .DESCRIPTION
        Uses the configured VerbParseRegex to extract meaningful names from
        application-specific verb ID patterns. Falls back to raw ID if no match.
    #>
    [CmdletBinding()]
    param(
        [string]$VerbId
    )
    
    # Use configured regex if available
    $pattern = $Script:Config.VerbParseRegex
    
    if ($pattern -and ($VerbId -match $pattern)) {
        $command = $Matches[1]
        
        # Add spaces before capitals for readability
        $readable = $command -creplace '([A-Z])', ' $1'
        return $readable.Trim()
    }
    
    # Fallback: return raw verb ID
    return $VerbId
}

function Get-BlockedStatus {
    <#
    .SYNOPSIS
        Checks if a CLSID is currently blocked in the registry
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Clsid
    )
    
    # Ensure braced format
    $bracedClsid = if ($Clsid -match '^\{') { $Clsid } else { "{$Clsid}" }
    
    try {
        $null = Get-ItemProperty -Path $Script:Config.BlockedExtensionsPath -Name $bracedClsid -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Set-ExtensionBlocked {
    <#
    .SYNOPSIS
        Blocks or unblocks a shell extension by CLSID
    .OUTPUTS
        Boolean indicating success
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Clsid,
        
        [switch]$Unblock
    )
    
    # Ensure braced format for registry
    $bracedClsid = if ($Clsid -match '^\{') { $Clsid } else { "{$Clsid}" }
    
    try {
        if ($Unblock) {
            Remove-ItemProperty -Path $Script:Config.BlockedExtensionsPath -Name $bracedClsid -ErrorAction Stop
        }
        else {
            Set-ItemProperty -Path $Script:Config.BlockedExtensionsPath -Name $bracedClsid -Value "" -Type String -Force -ErrorAction Stop
        }
        return $true
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # Property doesn't exist (OK for unblock)
        return $true
    }
    catch {
        Write-Log "Registry operation failed for $bracedClsid : $_" -Level Error
        return $false
    }
}

function Restart-ExplorerShell {
    <#
    .SYNOPSIS
        Restarts Windows Explorer to apply registry changes
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )
    
    if (-not $Force -and -not $Script:Config.AutoRestartExplorer) {
        Write-Host ""
        $response = Read-Host "Restart Explorer to apply changes? [Y/n]"
        if ($response -match '^[Nn]') {
            Write-Log "Explorer restart skipped. Changes apply after login or manual restart." -Level Warning
            return
        }
    }
    
    Write-Log "Restarting Explorer shell..." -Level Info
    
    try {
        # Gracefully stop explorer
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        
        # Wait for termination
        $timeout = 10
        $elapsed = 0
        while ((Get-Process -Name explorer -ErrorAction SilentlyContinue) -and ($elapsed -lt $timeout)) {
            Start-Sleep -Milliseconds 500
            $elapsed += 0.5
        }
        
        # Explorer should restart automatically on Windows 10/11
        # If not, start it manually
        Start-Sleep -Seconds 2
        
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
            Start-Sleep -Seconds 1
        }
        
        Write-Log "Explorer restarted successfully" -Level Success
    }
    catch {
        Write-Log "Explorer restart encountered an issue: $_" -Level Warning
        Write-Log "Please restart Explorer manually or log out/in" -Level Warning
    }
}

function Export-BlockerState {
    <#
    .SYNOPSIS
        Exports current blocking state to a JSON file for backup/restore
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Entries
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "$($Script:Config.AppName)_ContextMenuState_$timestamp.json"
    $outputPath = Join-Path $Script:Config.BackupPath $filename
    
    $state = @{
        ExportDate   = Get-Date -Format "o"
        AppName      = $Script:Config.AppName
        TotalEntries = $Entries.Count
        Entries      = @()
    }
    
    foreach ($entry in $Entries) {
        $isBlocked = Get-BlockedStatus -Clsid $entry.Clsid
        
        $state.Entries += @{
            Verb        = $entry.Verb
            Clsid       = $entry.Clsid
            Scope       = $entry.Scope
            Category    = $entry.Category
            IsBlocked   = $isBlocked
        }
    }
    
    try {
        # Ensure backup directory exists
        if (-not (Test-Path $Script:Config.BackupPath)) {
            New-Item -Path $Script:Config.BackupPath -ItemType Directory -Force | Out-Null
        }
        
        $state | ConvertTo-Json -Depth 10 | Set-Content -Path $outputPath -Encoding UTF8
        Write-Log "State exported to: $outputPath" -Level Success
        return $outputPath
    }
    catch {
        Write-Log "Failed to export state: $_" -Level Error
        return $null
    }
}

function Import-BlockerState {
    <#
    .SYNOPSIS
        Imports and applies a previously exported state
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ImportPath
    )
    
    if (-not (Test-Path $ImportPath)) {
        Write-Log "Import file not found: $ImportPath" -Level Error
        return $false
    }
    
    try {
        $state = Get-Content $ImportPath -Raw | ConvertFrom-Json
        
        $blocked = 0
        $unblocked = 0
        
        foreach ($entry in $state.Entries) {
            if ($entry.IsBlocked) {
                Set-ExtensionBlocked -Clsid $entry.Clsid
                $blocked++
            }
            else {
                Set-ExtensionBlocked -Clsid $entry.Clsid -Unblock
                $unblocked++
            }
        }
        
        Write-Log "Imported state: $blocked blocked, $unblocked unblocked" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to import state: $_" -Level Error
        return $false
    }
}

#region ========================================================================
#                                UI FUNCTIONS

#endregion =====================================================================

# -- Fixed width constant for all box rendering --
$Script:BoxWidth = 69

function Write-BoxLine {
    <#
    .SYNOPSIS
        Renders a single line inside a box with multiple colored segments,
        automatically padding to ensure perfect right-border alignment.
    #>
    param(
        [array]$Segments,
        [string]$BorderChar = $Script:B.V,
        [string]$BorderColor = "White",
        [string]$Pad = " ",
        [int]$Indent = 2
    )

    $RawText = $Pad
    foreach ($seg in $Segments) {
        $RawText += $seg.Text
    }

    $PaddingNeeded = $Script:BoxWidth - $RawText.Length
    if ($PaddingNeeded -lt 0) { $PaddingNeeded = 0 }

    $indentStr = ' ' * $Indent
    Write-Host "$indentStr$BorderChar" -ForegroundColor $BorderColor -NoNewline
    Write-Host $Pad -NoNewline

    foreach ($seg in $Segments) {
        Write-Host $seg.Text -ForegroundColor $seg.Color -NoNewline
    }

    Write-Host "$(' ' * $PaddingNeeded)$BorderChar" -ForegroundColor $BorderColor
}

function Write-BoxBorder {
    <#
    .SYNOPSIS
        Renders a horizontal border line (top, middle, or bottom) of a box.
    #>
    param(
        [string]$Left  = $Script:B.TL,
        [string]$Fill  = $Script:B.H,
        [string]$Right = $Script:B.TR,
        [string]$Color = "White",
        [int]$Indent = 2
    )
    $indentStr = ' ' * $Indent
    Write-Host "$indentStr$Left$($Fill * $Script:BoxWidth)$Right" -ForegroundColor $Color
}

function Write-BoxEmpty {
    <#
    .SYNOPSIS
        Renders an empty line inside a box (border + spaces + border).
    #>
    param(
        [string]$BorderChar = $Script:B.V,
        [string]$BorderColor = "White",
        [int]$Indent = 2
    )
    $indentStr = ' ' * $Indent
    Write-Host "$indentStr$BorderChar$(' ' * $Script:BoxWidth)$BorderChar" -ForegroundColor $BorderColor
}

function Show-Banner {
    if ($Script:UseUnicode) {
        Show-BannerUnicode
    } else {
        Show-BannerAscii
    }
}

function Show-BannerUnicode {
    $f = $Script:B.FB
    $t = $Script:B.TL
    $b = $Script:B.BR
    $h = $Script:B.H
    $v = $Script:B.V

    $bannerWidth = 76

    Write-Host ""
    Write-Host "  $($Script:B.TL)$($Script:B.H * $bannerWidth)$($Script:B.TR)" -ForegroundColor Cyan

    $bannerLines = @(
        "",
        "   $f$f$f$f$f$f$f$t$f$f$t  $f$f$t$f$f$f$f$f$f$f$t$f$f$t     $f$f$t          $f$f$f$f$f$f$f$t$f$f$t  $f$f$t$f$f$f$f$f$f$f$f$t   ",
        "   $f$f$t$h$h$h$h$b$f$f$t  $f$f$t$f$f$t$h$h$h$h$b$f$f$t     $f$f$t          $f$f$t$h$h$h$h$b$($Script:B.BL)$f$f$t$f$f$t$b$($Script:B.BL)$h$h$f$f$t$h$h$b   ",
        "   $f$f$f$f$f$f$f$t$f$f$f$f$f$f$f$t$f$f$f$f$f$t  $f$f$t     $f$f$t          $f$f$f$f$f$t   $($Script:B.BL)$f$f$f$t$b    $f$f$t      ",
        "   $($Script:B.BL)$h$h$h$h$f$f$t$f$f$t$h$h$f$f$t$f$f$t$h$h$b  $f$f$t     $f$f$t          $f$f$t$h$h$b   $f$f$t$f$f$t    $f$f$t      ",
        "   $f$f$f$f$f$f$f$t$f$f$t  $f$f$t$f$f$f$f$f$f$f$t$f$f$f$f$f$f$f$t$f$f$f$f$f$f$f$t     $f$f$f$f$f$f$f$t$f$f$t$b $f$f$t   $f$f$t      ",
        "   $($Script:B.BL)$h$h$h$h$h$h$b$($Script:B.BL)$b  $($Script:B.BL)$b$($Script:B.BL)$h$h$h$h$h$h$b$($Script:B.BL)$h$h$h$h$h$h$b$($Script:B.BL)$h$h$h$h$h$h$b     $($Script:B.BL)$h$h$h$h$h$h$b$($Script:B.BL)$b  $($Script:B.BL)$b   $($Script:B.BL)$b      ",
        "",
        "                      Context Menu Blocker                                  ",
        ""
    )

    foreach ($line in $bannerLines) {
        $padded = $line.PadRight($bannerWidth)
        if ($padded.Length -gt $bannerWidth) { $padded = $padded.Substring(0, $bannerWidth) }
        Write-Host "  $($Script:B.V)" -ForegroundColor Cyan -NoNewline
        Write-Host $padded -ForegroundColor Cyan -NoNewline
        Write-Host "$($Script:B.V)" -ForegroundColor Cyan
    }

    Write-Host "  $($Script:B.BL)$($Script:B.H * $bannerWidth)$($Script:B.BR)" -ForegroundColor Cyan
}

function Show-BannerAscii {
    $w = 76

    Write-Host ""
    Write-Host "  +$('=' * $w)+" -ForegroundColor Cyan

    $asciiLines = @(
        "",
        "    ____  _   _ _____ _     _          _____  ____  _____",
        "   / ___|| | | | ____| |   | |        | ____|\ \/ /|_   _|",
        "   \___ \| |_| |  _| | |   | |        |  _|   \  /   | |",
        "    ___) |  _  | |___| |___| |___     | |___  /  \   | |",
        "   |____/|_| |_|_____|_____|_____|    |_____|/_/\_\  |_|",
        "",
        "                    Context Menu Blocker",
        ""
    )

    foreach ($line in $asciiLines) {
        $padded = $line.PadRight($w)
        if ($padded.Length -gt $w) { $padded = $padded.Substring(0, $w) }
        Write-Host "  |" -ForegroundColor Cyan -NoNewline
        Write-Host $padded -ForegroundColor Cyan -NoNewline
        Write-Host "|" -ForegroundColor Cyan
    }

    Write-Host "  +$('=' * $w)+" -ForegroundColor Cyan
}

function Show-MainMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Entries,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$SelectedPackage
    )
    
    $blockedCount = ($Entries | Where-Object { Get-BlockedStatus -Clsid $_.Clsid }).Count
    $totalCount = $Entries.Count
    $visibleCount = $totalCount - $blockedCount
    
    $visibleColor = if ($visibleCount -eq 0) { "DarkGray" } else { "Red" }
    
    # -- Info Box (DarkGray, single-line style) --
    Write-Host ""
    Write-BoxBorder -Left $Script:B.sTL -Fill $Script:B.sH -Right $Script:B.sTR -Color DarkGray
    
    Write-BoxLine -BorderChar $Script:B.sV -BorderColor DarkGray -Segments @(
        @{ Text = "Target Application: "; Color = "White" },
        @{ Text = "$($Script:Config.AppName)"; Color = "Cyan" }
    )
    
    Write-BoxLine -BorderChar $Script:B.sV -BorderColor DarkGray -Segments @(
        @{ Text = "Package Version:    "; Color = "White" },
        @{ Text = "$($SelectedPackage.Version)"; Color = "Cyan" }
    )
    
    Write-BoxBorder -Left $Script:B.sLT -Fill $Script:B.sH -Right $Script:B.sRT -Color DarkGray
    
    Write-BoxLine -BorderChar $Script:B.sV -BorderColor DarkGray -Segments @(
        @{ Text = "Context Menu Entries: "; Color = "White" },
        @{ Text = "$totalCount total"; Color = "White" },
        @{ Text = " $($Script:B.sV) "; Color = "DarkGray" },
        @{ Text = "$blockedCount blocked"; Color = "Green" },
        @{ Text = " $($Script:B.sV) "; Color = "DarkGray" },
        @{ Text = "$visibleCount visible"; Color = $visibleColor }
    )
    
    Write-BoxBorder -Left $Script:B.sBL -Fill $Script:B.sH -Right $Script:B.sBR -Color DarkGray
    
    # -- Main Menu Box (White, double-line style) --
    Write-Host ""
    Write-BoxBorder
    
    Write-BoxLine -Pad "" -Segments @(
        @{ Text = "                         MAIN MENU"; Color = "White" }
    )
    
    Write-BoxBorder -Left $Script:B.LT -Fill $Script:B.H -Right $Script:B.RT
    Write-BoxEmpty
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[1]"; Color = "Yellow" },
        @{ Text = "  Block ALL context menu entries         "; Color = "White" },
        @{ Text = "(Recommended)"; Color = "Green" }
    )
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[2]"; Color = "Yellow" },
        @{ Text = "  Unblock ALL context menu entries"; Color = "White" }
    )
    
    Write-BoxEmpty
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[3]"; Color = "Cyan" },
        @{ Text = "  View all entries with current status"; Color = "White" }
    )
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[4]"; Color = "Cyan" },
        @{ Text = "  Selective blocking (interactive)"; Color = "White" }
    )
    
    Write-BoxEmpty
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[5]"; Color = "DarkGray" },
        @{ Text = "  Export current state (backup)"; Color = "White" }
    )
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[6]"; Color = "DarkGray" },
        @{ Text = "  Import state from backup"; Color = "White" }
    )
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[7]"; Color = "DarkGray" },
        @{ Text = "  Rescan packages"; Color = "White" }
    )
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[8]"; Color = "DarkGray" },
        @{ Text = "  Restart Explorer"; Color = "White" }
    )
    
    Write-BoxEmpty
    
    Write-BoxLine -Segments @(
        @{ Text = "  "; Color = "White" },
        @{ Text = "[0]"; Color = "Red" },
        @{ Text = "  Exit"; Color = "White" }
    )
    
    Write-BoxEmpty
    Write-BoxBorder -Left $Script:B.BL -Fill $Script:B.H -Right $Script:B.BR
    Write-Host ""
    
    return Read-Host "  Select option"
}

function Show-EntryList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Entries
    )
    
    Write-Host ""
    Write-BoxBorder -Left $Script:B.TL -Fill $Script:B.H -Right $Script:B.TR -Color Cyan
    Write-BoxLine -BorderChar $Script:B.V -BorderColor Cyan -Pad "" -Segments @(
        @{ Text = "                        CONTEXT MENU ENTRIES"; Color = "Cyan" }
    )
    Write-BoxBorder -Left $Script:B.BL -Fill $Script:B.H -Right $Script:B.BR -Color Cyan
    
    $cloudEntries = @($Entries | Where-Object { $_.Category -eq "CloudFiles" })
    $fileExplorerEntries = @($Entries | Where-Object { $_.Category -eq "FileExplorer" })
    
    # CloudFiles section header
    $cloudHeader = " CloudFiles Entries ($($cloudEntries.Count)) "
    $cloudFill = $Script:BoxWidth - $cloudHeader.Length - 1
    if ($cloudFill -lt 0) { $cloudFill = 0 }
    
    Write-Host ""
    Write-Host "  $($Script:B.sTL)$($Script:B.sH)$cloudHeader$($Script:B.sH * $cloudFill)$($Script:B.sTR)" -ForegroundColor Yellow
    Write-BoxLine -BorderChar $Script:B.sV -BorderColor Yellow -Pad " " -Segments @(
        @{ Text = "These appear only when right-clicking inside the $($Script:Config.AppName) folder"; Color = "DarkGray" }
    )
    Write-Host "  $($Script:B.sBL)$($Script:B.sH * $Script:BoxWidth)$($Script:B.sBR)" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($entry in $cloudEntries) {
        $isBlocked = Get-BlockedStatus -Clsid $entry.Clsid
        $statusIcon = if ($isBlocked) { $Script:B.Blk } else { $Script:B.Emp }
        $statusText = if ($isBlocked) { "BLOCKED" } else { "VISIBLE" }
        $statusColor = if ($isBlocked) { "Green" } else { "Red" }
        
        Write-Host "    " -NoNewline
        Write-Host $statusIcon -ForegroundColor $statusColor -NoNewline
        Write-Host " [$statusText] " -ForegroundColor $statusColor -NoNewline
        Write-Host $entry.Description -ForegroundColor White
        Write-Host "      " -NoNewline
        Write-Host "CLSID: {$($entry.Clsid)}" -ForegroundColor DarkGray
    }
    
    # FileExplorer section header
    $feHeader = " FileExplorer Entries ($($fileExplorerEntries.Count)) "
    $feFill = $Script:BoxWidth - $feHeader.Length - 1
    if ($feFill -lt 0) { $feFill = 0 }
    
    Write-Host ""
    Write-Host "  $($Script:B.sTL)$($Script:B.sH)$feHeader$($Script:B.sH * $feFill)$($Script:B.sTR)" -ForegroundColor Yellow
    Write-BoxLine -BorderChar $Script:B.sV -BorderColor Yellow -Pad " " -Segments @(
        @{ Text = "These appear on ALL files and folders everywhere"; Color = "DarkGray" }
    )
    Write-Host "  $($Script:B.sBL)$($Script:B.sH * $Script:BoxWidth)$($Script:B.sBR)" -ForegroundColor Yellow
    Write-Host ""
    
    foreach ($entry in $fileExplorerEntries) {
        $isBlocked = Get-BlockedStatus -Clsid $entry.Clsid
        $statusIcon = if ($isBlocked) { $Script:B.Blk } else { $Script:B.Emp }
        $statusText = if ($isBlocked) { "BLOCKED" } else { "VISIBLE" }
        $statusColor = if ($isBlocked) { "Green" } else { "Red" }
        
        Write-Host "    " -NoNewline
        Write-Host $statusIcon -ForegroundColor $statusColor -NoNewline
        Write-Host " [$statusText] " -ForegroundColor $statusColor -NoNewline
        Write-Host $entry.Description -ForegroundColor White
        Write-Host "      " -NoNewline
        Write-Host "CLSID: {$($entry.Clsid)}" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    Write-BoxBorder -Left $Script:B.TL -Fill $Script:B.H -Right $Script:B.TR -Color Cyan
    Write-BoxBorder -Left $Script:B.BL -Fill $Script:B.H -Right $Script:B.BR -Color Cyan
    Write-Host ""
}

function Invoke-SelectiveBlocking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Entries
    )
    
    Write-Host ""
    Write-BoxBorder -Left $Script:B.TL -Fill $Script:B.H -Right $Script:B.TR -Color Cyan
    Write-BoxLine -BorderChar $Script:B.V -BorderColor Cyan -Pad "" -Segments @(
        @{ Text = "                       SELECTIVE BLOCKING MODE"; Color = "Cyan" }
    )
    Write-BoxBorder -Left $Script:B.BL -Fill $Script:B.H -Right $Script:B.BR -Color Cyan
    Write-Host ""
    Write-Host "  For each entry, press:" -ForegroundColor Yellow
    Write-Host "    [B] Block   [U] Unblock   [S] Skip   [Q] Quit" -ForegroundColor White
    Write-Host ""
    
    $modified = 0
    $index = 0
    
    foreach ($entry in $Entries) {
        $index++
        $isBlocked = Get-BlockedStatus -Clsid $entry.Clsid
        $statusText = if ($isBlocked) { "BLOCKED" } else { "VISIBLE" }
        $statusColor = if ($isBlocked) { "Green" } else { "Red" }
        
        Write-Host "  [$index/$($Entries.Count)] " -ForegroundColor DarkGray -NoNewline
        Write-Host "[$statusText] " -ForegroundColor $statusColor -NoNewline
        Write-Host "$($entry.Description)" -ForegroundColor White
        Write-Host "           Scope: $($entry.Scope) | CLSID: {$($entry.Clsid)}" -ForegroundColor DarkGray
        Write-Host "           Action [B/U/S/Q]: " -NoNewline
        
        $validInput = $false
        while (-not $validInput) {
            $key = [Console]::ReadKey($true).KeyChar.ToString().ToLower()
            if ($key -match '^[busq]$') {
                $validInput = $true
            }
        }
        
        switch ($key) {
            'b' { 
                if (Set-ExtensionBlocked -Clsid $entry.Clsid) {
                    Write-Host "BLOCKED" -ForegroundColor Green
                    $modified++
                } else {
                    Write-Host "FAILED" -ForegroundColor Red
                }
            }
            'u' { 
                if (Set-ExtensionBlocked -Clsid $entry.Clsid -Unblock) {
                    Write-Host "UNBLOCKED" -ForegroundColor Yellow
                    $modified++
                } else {
                    Write-Host "FAILED" -ForegroundColor Red
                }
            }
            's' { 
                Write-Host "SKIPPED" -ForegroundColor DarkGray
            }
            'q' { 
                Write-Host "QUIT" -ForegroundColor Red
                Write-Host ""
                break
            }
        }
        
        if ($key -eq 'q') { break }
    }
    
    Write-Host ""
    Write-Log "Selective blocking complete: $modified entries modified" -Level Info
    
    return $modified
}

function Show-PackageList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Packages
    )
    
    Write-Host ""
    Write-Host "  Found $($Packages.Count) $($Script:Config.AppName) package(s):" -ForegroundColor Yellow
    Write-Host ""
    
    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $pkg = $Packages[$i]
        $marker = if ($i -eq 0) { " $($Script:B.Arr) ACTIVE (newest)" } else { "" }
        $color = if ($i -eq 0) { "Green" } else { "DarkGray" }
        
        Write-Host "    $($i + 1). " -ForegroundColor White -NoNewline
        Write-Host "v$($pkg.Version)" -ForegroundColor $color -NoNewline
        Write-Host "$marker" -ForegroundColor Green
        Write-Host "       Modified: $($pkg.LastModified.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor DarkGray
    }
    
    Write-Host ""
}

function Wait-KeyPress {
    param(
        [string]$Message = "Press any key to continue..."
    )
    Write-Host ""
    Write-Host "  $Message" -ForegroundColor DarkGray
    $null = [Console]::ReadKey($true)
}

#region ========================================================================
#                                MAIN ENTRY POINT

function Main {
    
    # Initialize
    if (-not (Initialize-Environment)) {
        Write-Log "Initialization failed" -Level Error
        if (-not $NoPrompt) { Wait-KeyPress "Press any key to exit..." }
        return
    }
    
    Write-Log "Script started - Target: $($Script:Config.AppName)" -Level Info
    
    # -------------------------------------------------------------------------
    # NON-INTERACTIVE MODE
    # -------------------------------------------------------------------------
    
    if ($BlockAll -or $UnblockAll) {
        # Find packages
        $packages = Get-AppPackageFolders
        
        if ($packages.Count -eq 0) {
            Write-Log "No $($Script:Config.AppName) packages found" -Level Error
            return
        }
        
        $selectedPackage = $packages[0]
        Write-Log "Using package: v$($selectedPackage.Version)" -Level Info
        
        # Get entries
        $entries = Get-ContextMenuEntries -ManifestPath $selectedPackage.ManifestPath
        
        if ($entries.Count -eq 0) {
            Write-Log "No context menu entries found" -Level Error
            return
        }
        
        Write-Log "Found $($entries.Count) context menu entries" -Level Info
        
        # Apply action
        $success = 0
        $failed = 0
        
        foreach ($entry in $entries) {
            $result = if ($BlockAll) {
                Set-ExtensionBlocked -Clsid $entry.Clsid
            } else {
                Set-ExtensionBlocked -Clsid $entry.Clsid -Unblock
            }
            
            if ($result) { $success++ } else { $failed++ }
        }
        
        $action = if ($BlockAll) { "blocked" } else { "unblocked" }
        Write-Log "Successfully $action $success entries ($failed failed)" -Level Success
        
        # Restart Explorer if requested
        if (-not $NoRestartExplorer) {
            Restart-ExplorerShell -Force
        }
        
        return
    }
    
    # -------------------------------------------------------------------------
    # INTERACTIVE MODE
    # -------------------------------------------------------------------------
    
    while ($true) {
        Clear-Host
        Show-Banner
        
        # Find packages
        $packages = Get-AppPackageFolders
        
        if ($packages.Count -eq 0) {
            Write-Log "No $($Script:Config.AppName) packages found in WindowsApps" -Level Error
            Write-Host ""
            Write-Host "  Possible causes:" -ForegroundColor Yellow
            Write-Host "    * $($Script:Config.AppName) is not installed from Microsoft Store" -ForegroundColor White
            Write-Host "    * The package pattern may have changed" -ForegroundColor White
            Write-Host "    * Insufficient permissions to read WindowsApps" -ForegroundColor White
            Write-Host ""
            Wait-KeyPress "Press any key to exit..."
            return
        }
        
        Show-PackageList -Packages $packages
        
        $selectedPackage = $packages[0]
        
        # Parse manifest
        $entries = Get-ContextMenuEntries -ManifestPath $selectedPackage.ManifestPath
        
        if ($entries.Count -eq 0) {
            Write-Log "No context menu entries found in manifest" -Level Warning
            Write-Host "  This is unusual. The manifest may have changed format." -ForegroundColor Yellow
            Wait-KeyPress
            continue
        }
        
        # Show menu
        $choice = Show-MainMenu -Entries $entries -SelectedPackage $selectedPackage
        
        switch ($choice) {
            "1" {
                # Block ALL
                Write-Host ""
                Write-Log "Blocking all $($entries.Count) context menu entries..." -Level Info
                
                $success = 0
                $failed = 0
                
                foreach ($entry in $entries) {
                    if (Set-ExtensionBlocked -Clsid $entry.Clsid) {
                        $success++
                    } else {
                        $failed++
                    }
                }
                
                if ($failed -eq 0) {
                    Write-Log "Successfully blocked all $success entries" -Level Success
                } else {
                    Write-Log "Blocked $success entries, $failed failed" -Level Warning
                }
                
                Restart-ExplorerShell
                Wait-KeyPress
            }
            
            "2" {
                # Unblock ALL
                Write-Host ""
                Write-Log "Unblocking all $($entries.Count) context menu entries..." -Level Info
                
                $success = 0
                $failed = 0
                
                foreach ($entry in $entries) {
                    if (Set-ExtensionBlocked -Clsid $entry.Clsid -Unblock) {
                        $success++
                    } else {
                        $failed++
                    }
                }
                
                if ($failed -eq 0) {
                    Write-Log "Successfully unblocked all $success entries" -Level Success
                } else {
                    Write-Log "Unblocked $success entries, $failed failed" -Level Warning
                }
                
                Restart-ExplorerShell
                Wait-KeyPress
            }
            
            "3" {
                # View all entries
                Show-EntryList -Entries $entries
                Wait-KeyPress
            }
            
            "4" {
                # Selective blocking
                $modified = Invoke-SelectiveBlocking -Entries $entries
                if ($modified -gt 0) {
                    Restart-ExplorerShell
                }
                Wait-KeyPress
            }
            
            "5" {
                # Export state
                Write-Host ""
                Export-BlockerState -Entries $entries
                Wait-KeyPress
            }
            
            "6" {
                # Import state
                Write-Host ""
                Write-Host "  Enter path to backup file:" -ForegroundColor Yellow
                $importPath = Read-Host "  Path"
                
                if ($importPath -and (Test-Path $importPath)) {
                    Import-BlockerState -ImportPath $importPath
                    Restart-ExplorerShell
                } else {
                    Write-Log "File not found: $importPath" -Level Error
                }
                Wait-KeyPress
            }
            
            "7" {
                # Rescan - just continue the loop
                continue
            }
            
            "8" {
                # Restart Explorer
                Restart-ExplorerShell -Force
                Wait-KeyPress
            }
            
            "0" {
                # Exit
                Write-Log "Exiting..." -Level Info
                return
            }
            
            default {
                Write-Host "  Invalid option. Please enter 0-8." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

#endregion =====================================================================

# Start script
Main
Write-Host ""
Write-Host "Script finished. You may close this window or continue using the shell." -ForegroundColor DarkGray
