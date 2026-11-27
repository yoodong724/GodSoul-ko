# KoreanPatch Windows runtime for the koreanpatch-windows-v2 contract.
# Maintained in korean-localization-framework runtime/windows; projects reuse it unchanged.
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('install','restore')]
    [string]$Action
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PatchRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$GameRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PatchRoot))
$StateDir = [IO.Path]::Combine($PatchRoot, 'state')
$ActivePath = [IO.Path]::Combine($StateDir, 'active.json')
$ReceiptPath = [IO.Path]::Combine($StateDir, 'last-restored.json')
$BackupRoot = [IO.Path]::Combine($PatchRoot, 'backup')
$WorkRoot = [IO.Path]::Combine($PatchRoot, 'work')
$Utf8 = New-Object System.Text.UTF8Encoding($false)
# Windows PowerShell 5.1 cannot rely on long path support, so every path must fit MAX_PATH.
$MaxPathLength = 259
$MaxDirectoryLength = 247
$Separator = [IO.Path]::DirectorySeparatorChar

function Get-ShaBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-ShaFile([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Assert-Sha([string]$Value) {
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid SHA-256 in manifest.' }
}
function Write-Count([string]$Label, [int]$Done, [int]$Total) {
    if ($Total -ge 100 -and ($Done % 100 -eq 0 -or $Done -eq $Total)) { Write-Host ('  {0} {1}/{2}' -f $Label, $Done, $Total) }
}
function Assert-PathLength([string]$Path) {
    if ($Path.Length -gt $MaxPathLength -or $Path.LastIndexOf($Separator) -gt $MaxDirectoryLength) {
        throw "Windows path limit exceeded ($($Path.Length) characters): $Path. Use a game folder with a shorter path."
    }
}
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Link or reparse point is not supported: $current" }
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}
function Resolve-Relative([string]$Root, [string]$Relative, [bool]$GameTarget) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains('\')) { throw "Invalid relative path: $Relative" }
    $segments = $Relative.Split('/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..' -or $segment -match '[<>:"|?*\x00-\x1f]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { throw "Invalid Windows path: $Relative" }
    }
    if ($GameTarget -and [StringComparer]::OrdinalIgnoreCase.Equals($segments[0], 'KoreanPatch')) { throw 'Manifest target overlaps KoreanPatch.' }
    $native = $Relative.Replace('/', $Separator)
    $prefix = $Root.TrimEnd($Separator) + $Separator
    # Check the length before any .NET path API sees a path that may exceed MAX_PATH.
    $candidate = $prefix + $native
    Assert-PathLength $candidate
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside its root: $Relative" }
    Assert-NoReparse $full
    return $full
}
function Read-Json([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { throw "Missing JSON file: $Path" }
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Save-Json([string]$Path, $Value) {
    $dir = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $temp = [IO.Path]::Combine($dir, '.state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($temp, $json, $Utf8)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Save-Active($State) { Save-Json $ActivePath $State }
function Is-Delta($Operation) {
    return $null -ne $Operation.PSObject.Properties['delta_format']
}
function Expand-Delta([string]$Original,[string]$Delta,[string]$Output,[long]$ResultSize) {
    if (-not ('KoreanPatchDelta' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class KoreanPatchDelta {
    static void CopyBytes(Stream src, Stream dst, ulong count, byte[] buffer) {
        while (count != 0) {
            int take = (int)Math.Min((ulong)buffer.Length, count);
            int n = src.Read(buffer, 0, take);
            if (n == 0) throw new InvalidDataException("Truncated delta or original");
            dst.Write(buffer, 0, n); count -= (ulong)n;
        }
    }
    public static void Apply(string original, string delta, string output, long expectedSize) {
        using (var src = new FileStream(original, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (var patch = new FileStream(delta, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (var reader = new BinaryReader(patch, Encoding.ASCII))
        using (var dst = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            if (Encoding.ASCII.GetString(reader.ReadBytes(8)) != "KPDIF001") throw new InvalidDataException("Invalid delta header");
            ulong commands = reader.ReadUInt64(), size = reader.ReadUInt64(), written = 0;
            if (size != (ulong)expectedSize || commands > (ulong)(patch.Length / 9)) throw new InvalidDataException("Invalid delta size or count");
            byte[] buffer = new byte[1024 * 1024];
            for (ulong i = 0; i < commands; i++) {
                byte kind = reader.ReadByte(); ulong length;
                if (kind == 0) {
                    ulong offset = reader.ReadUInt64(); length = reader.ReadUInt64();
                    if (offset > (ulong)src.Length || length > (ulong)src.Length - offset) throw new InvalidDataException("COPY outside original");
                    src.Position = (long)offset;
                    if (length == 0 || length > size - written) throw new InvalidDataException("Invalid COPY length");
                    CopyBytes(src, dst, length, buffer);
                } else if (kind == 1) {
                    length = reader.ReadUInt64();
                    if (length == 0 || length > size - written || length > (ulong)(patch.Length - patch.Position)) throw new InvalidDataException("Invalid ADD length");
                    CopyBytes(patch, dst, length, buffer);
                } else throw new InvalidDataException("Invalid delta opcode");
                written += length;
            }
            if (written != size || patch.Position != patch.Length) throw new InvalidDataException("Delta length or trailing data mismatch");
        }
    }
}
'@
    }
    [KoreanPatchDelta]::Apply($Original,$Delta,$Output,$ResultSize)
}
function Check-Manifest($Manifest) {
    if ($Manifest.format -ne 'koreanpatch-windows-v2/manifest-v1' -or [string]::IsNullOrWhiteSpace([string]$Manifest.game_id) -or [string]::IsNullOrWhiteSpace([string]$Manifest.patch_id)) { throw 'Unsupported manifest or missing identity.' }
    if (@($Manifest.requirements).Count -lt 1 -or @($Manifest.operations).Count -lt 1) { throw 'At least one game identity requirement and operation are required.' }
    # State and backup files live under KoreanPatch, so a long game folder path can break them too.
    Assert-PathLength ([IO.Path]::Combine($StateDir, '.state-' + ('0' * 32) + '.tmp'))
    Assert-PathLength ([IO.Path]::Combine($BackupRoot, ('0' * 32), ([Math]::Max(@($Manifest.operations).Count - 1, 0)).ToString('D4') + '.bin'))
    foreach ($req in @($Manifest.requirements)) {
        if ($null -eq $req) { throw 'Null requirement.' }
        Assert-Sha ([string]$req.sha256)
        $null = Resolve-Relative $GameRoot ([string]$req.path) $true
    }
    $seen = New-Object 'System.Collections.Generic.List[string]'
    foreach ($op in @($Manifest.operations)) {
        if ($null -eq $op -or $op.kind -notin @('add','replace')) { throw 'Invalid file operation.' }
        $relative = [string]$op.path
        $target = Resolve-Relative $GameRoot $relative $true
        Assert-PathLength ($target.Substring(0, $target.LastIndexOf($Separator) + 1) + '.koreanpatch-' + ('0' * 32) + '.tmp')
        foreach ($prior in $seen) {
            if ([StringComparer]::OrdinalIgnoreCase.Equals($relative,$prior) -or $relative.StartsWith($prior+'/',[StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($relative+'/',[StringComparison]::OrdinalIgnoreCase)) { throw "Duplicate or overlapping paths: $relative" }
        }
        $seen.Add($relative)
        if ($op.kind -eq 'replace') { Assert-Sha ([string]$op.before_sha256) }
        elseif ($null -ne $op.before_sha256) { throw 'Add operation must expect absence.' }
        Assert-Sha ([string]$op.payload_sha256); Assert-Sha ([string]$op.after_sha256)
        if (Is-Delta $op) {
            Assert-PathLength ([IO.Path]::Combine($WorkRoot, '.koreanpatch-' + ('0' * 32) + '.tmp'))
            if ($op.kind -ne 'replace' -or [string]$op.delta_format -cne 'KPDIF001' -or $null -eq $op.PSObject.Properties['result_size'] -or ($op.result_size -isnot [long] -and $op.result_size -isnot [int]) -or [long]$op.result_size -le 0) { throw 'Invalid delta operation.' }
        } elseif ([string]$op.payload_sha256 -ine [string]$op.after_sha256) { throw 'Payload and installed hash must match for a direct file operation.' }
        if (-not ([string]$op.payload).StartsWith('payload/',[StringComparison]::OrdinalIgnoreCase)) { throw 'Payload must be under payload/.' }
        $null = Resolve-Relative $PatchRoot ([string]$op.payload) $false
    }
}
function Check-Requirements($Manifest) {
    $requirements = @($Manifest.requirements)
    $done = 0
    foreach ($req in $requirements) {
        $p = Resolve-Relative $GameRoot ([string]$req.path) $true
        if (-not [IO.File]::Exists($p) -or (Get-ShaFile $p) -ine [string]$req.sha256) { throw "Unsupported game or changed requirement: $($req.path)" }
        $done++
        Write-Count 'Game files checked:' $done $requirements.Count
    }
}
function Check-NewInstall($Manifest) {
    Check-Requirements $Manifest
    [long]$space = 1048576
    $operations = @($Manifest.operations)
    $done = 0
    foreach ($op in $operations) {
        $target = Resolve-Relative $GameRoot ([string]$op.path) $true
        $payload = Resolve-Relative $PatchRoot ([string]$op.payload) $false
        if (-not [IO.File]::Exists($payload) -or (Get-ShaFile $payload) -ine [string]$op.payload_sha256) { throw "Payload missing or changed: $($op.payload)" }
        $space += (New-Object IO.FileInfo($payload)).Length
        if (Is-Delta $op) { $space += 2 * [long]$op.result_size }
        if ($op.kind -eq 'add') {
            if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw "Add target already exists: $($op.path)" }
        } else {
            if (-not [IO.File]::Exists($target) -or (Get-ShaFile $target) -ine [string]$op.before_sha256) { throw "Original missing or changed: $($op.path)" }
            $space += (New-Object IO.FileInfo($target)).Length
            $open = [IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $open.Dispose()
        }
        $done++
        Write-Count 'Patch files checked:' $done $operations.Count
    }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($GameRoot))
    if ($drive.AvailableFreeSpace -lt $space) { throw 'Insufficient free space for payload and backups.' }
    if ([IO.Directory]::Exists($BackupRoot)) { throw 'Untracked backup directory exists; no files were removed.' }
}
function Read-State([string]$Path) {
    $s = Read-Json $Path
    if ($s.format -ne 'koreanpatch-windows-v2/state-v1' -or -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$s.game_root,$GameRoot) -or [string]$s.id -notmatch '^[a-f0-9]{32}$') { throw 'State belongs to another root or is invalid.' }
    if ([string]$s.status -notin @('preparing','applying','installed','restored_cleanup_pending','restored')) { throw 'Unknown installation state.' }
    if ($Path -eq $ActivePath -and $s.status -eq 'restored') { throw 'Active state conflicts with restored status.' }
    if ($Path -eq $ReceiptPath -and $s.status -ne 'restored') { throw 'Restored receipt has an invalid status.' }
    Assert-Sha ([string]$s.manifest_sha256)
    Check-Manifest $s.manifest
    return $s
}
function Backup-Path($State,[int]$Index) { return [IO.Path]::Combine($BackupRoot, [string]$State.id, ($Index.ToString('D4')+'.bin')) }
function Verify-Original($State) {
    foreach ($op in @($State.manifest.operations)) {
        $target = Resolve-Relative $GameRoot ([string]$op.path) $true
        if ($op.kind -eq 'replace') {
            if (-not [IO.File]::Exists($target) -or (Get-ShaFile $target) -ine [string]$op.before_sha256) { throw "Original not restored: $($op.path)" }
        } elseif ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw "Added file still exists: $($op.path)" }
    }
}
function Verify-Installed($State) {
    foreach ($req in @($State.manifest.requirements)) {
        $expected = [string]$req.sha256
        foreach ($op in @($State.manifest.operations)) {
            if ([StringComparer]::OrdinalIgnoreCase.Equals([string]$req.path,[string]$op.path)) {
                if ($op.kind -ne 'replace' -or $expected -ine [string]$op.before_sha256) { throw "Identity requirement conflicts with operation: $($req.path)" }
                $expected = [string]$op.after_sha256
                break
            }
        }
        $identity = Resolve-Relative $GameRoot ([string]$req.path) $true
        if (-not [IO.File]::Exists($identity) -or (Get-ShaFile $identity) -ine $expected) { throw "Unsupported game or changed requirement: $($req.path)" }
    }
    $operations = @($State.manifest.operations)
    $index = 0
    foreach ($op in $operations) {
        $target = Resolve-Relative $GameRoot ([string]$op.path) $true
        if (-not [IO.File]::Exists($target) -or (Get-ShaFile $target) -ine [string]$op.after_sha256) { throw "Installed file changed: $($op.path)" }
        $payload = Resolve-Relative $PatchRoot ([string]$op.payload) $false
        if (-not [IO.File]::Exists($payload) -or (Get-ShaFile $payload) -ine [string]$op.payload_sha256) { throw "Payload missing or changed: $($op.payload)" }
        if ($op.kind -eq 'replace') {
            $backup = Backup-Path $State $index
            if (-not [IO.File]::Exists($backup) -or (Get-ShaFile $backup) -ine [string]$op.before_sha256) { throw "Backup missing or changed: $($op.path)" }
        }
        $index++
        Write-Count 'Files verified:' $index $operations.Count
    }
}
function Ensure-Parents([string]$Target,$State) {
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $p = [IO.Path]::GetDirectoryName($Target)
    while (-not [IO.Directory]::Exists($p)) {
        $missing.Add($p)
        $p = [IO.Path]::GetDirectoryName($p)
        if (-not $p) { throw 'Cannot locate target parent.' }
    }
    for ($i=$missing.Count-1; $i -ge 0; $i--) {
        $dir = $missing[$i]; Assert-NoReparse $dir
        $State.created_dirs = @($State.created_dirs) + @($dir)
        Save-Active $State
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
}
function Copy-IntoTarget([string]$Source,[string]$Target,[string]$Hash,[bool]$Replace,$State) {
    $tmp = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Target), '.koreanpatch-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    if ([IO.File]::Exists($tmp) -or [IO.Directory]::Exists($tmp)) { throw 'Temporary path already exists.' }
    $State.temp_files = @($State.temp_files) + @($tmp)
    Save-Active $State
    try {
        [IO.File]::Copy($Source,$tmp,$false)
        if ((Get-ShaFile $tmp) -ine $Hash) { throw 'Temporary file hash mismatch.' }
        if ($Replace) { [IO.File]::Replace($tmp,$Target,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($tmp,$Target) }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Cleanup-Restored($State) {
    Write-Host 'Removing backups and temporary files...'
    Verify-Original $State
    foreach ($temp in @($State.temp_files)) {
        $temp = [string]$temp
        if ([IO.Path]::GetFileName($temp) -notmatch '^\.koreanpatch-[a-f0-9]{32}\.tmp$') { throw 'Invalid recorded temporary file.' }
        $validParent = $false
        foreach ($op in @($State.manifest.operations)) {
            $target = Resolve-Relative $GameRoot ([string]$op.path) $true
            if ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($temp),[IO.Path]::GetDirectoryName($target))) { $validParent = $true; break }
        }
        if ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($temp),$WorkRoot)) { $validParent = $true }
        if (-not $validParent) { throw 'Temporary file is outside its target directory.' }
        Assert-NoReparse $temp
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.Directory]::Exists($temp)) { throw 'Temporary path is a directory.' }
    }
    if ([IO.Directory]::Exists($WorkRoot) -and [IO.Directory]::GetFileSystemEntries($WorkRoot).Length -eq 0) { [IO.Directory]::Delete($WorkRoot,$false) }
    $index = 0
    foreach ($op in @($State.manifest.operations)) {
        if ($op.kind -eq 'replace') {
            $backup = Backup-Path $State $index
            if ([IO.File]::Exists($backup)) {
                if ((Get-ShaFile $backup) -ine [string]$op.before_sha256) { throw "Backup changed; cleanup refused: $($op.path)" }
                [IO.File]::Delete($backup)
            }
        }
        $index++
    }
    $own = [IO.Path]::Combine($BackupRoot,[string]$State.id)
    if ([IO.Directory]::Exists($own)) { [IO.Directory]::Delete($own,$false) }
    if ([IO.Directory]::Exists($BackupRoot)) { [IO.Directory]::Delete($BackupRoot,$false) }
    $dirs = @($State.created_dirs)
    for ($i=$dirs.Count-1; $i -ge 0; $i--) {
        $dir = [string]$dirs[$i]
        Assert-NoReparse $dir
        if ([IO.Directory]::Exists($dir) -and [IO.Directory]::GetFileSystemEntries($dir).Length -eq 0) { [IO.Directory]::Delete($dir,$false) }
    }
    $State.status = 'restored'
    Save-Json $ReceiptPath $State
    [IO.File]::Delete($ActivePath)
}
function Restore-State($State) {
    if ($State.status -eq 'restored_cleanup_pending') { Cleanup-Restored $State; return }
    $operations = @($State.manifest.operations)
    Write-Host 'Checking files to restore...'
    $index = 0
    foreach ($op in $operations) {
        $target = Resolve-Relative $GameRoot ([string]$op.path) $true
        if ($op.kind -eq 'replace') {
            if (-not [IO.File]::Exists($target)) { throw "Restore conflict; file missing: $($op.path)" }
            $actual = Get-ShaFile $target
            if ($actual -ine [string]$op.before_sha256 -and $actual -ine [string]$op.after_sha256) { throw "Restore conflict; file changed: $($op.path)" }
            if ($actual -ieq [string]$op.after_sha256 -and $actual -ine [string]$op.before_sha256) {
                $backup = Backup-Path $State $index
                if (-not [IO.File]::Exists($backup) -or (Get-ShaFile $backup) -ine [string]$op.before_sha256) { throw "Restore backup missing or changed: $($op.path)" }
            }
        } elseif ([IO.File]::Exists($target)) {
            if ((Get-ShaFile $target) -ine [string]$op.after_sha256) { throw "Restore conflict; added file changed: $($op.path)" }
        } elseif ([IO.Directory]::Exists($target)) { throw "Restore conflict; target is a directory: $($op.path)" }
        $index++
    }
    # Undo in reverse installation order so files applied last (for example catalogs) are restored first.
    Write-Host 'Restoring original files...'
    $done = 0
    for ($index = $operations.Count - 1; $index -ge 0; $index--) {
        $op = $operations[$index]
        $target = Resolve-Relative $GameRoot ([string]$op.path) $true
        if ($op.kind -eq 'replace') {
            if ((Get-ShaFile $target) -ine [string]$op.before_sha256) { Copy-IntoTarget (Backup-Path $State $index) $target ([string]$op.before_sha256) $true $State }
        } elseif ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
        $done++
        Write-Count 'Files restored:' $done $operations.Count
    }
    Verify-Original $State
    $State.status = 'restored_cleanup_pending'
    Save-Active $State
    Cleanup-Restored $State
}
function Install-Patch {
    $manifestPath = [IO.Path]::Combine($PatchRoot,'manifest.json')
    $manifest = Read-Json $manifestPath
    Check-Manifest $manifest
    $manifestHash = Get-ShaFile $manifestPath
    if ([IO.File]::Exists($ActivePath)) {
        $active = Read-State $ActivePath
        if ($active.status -eq 'installed') {
            if ([string]$active.manifest_sha256 -ine $manifestHash) { throw 'Another patch snapshot is active; restore it first.' }
            Write-Host 'Checking the installed patch...'
            Verify-Installed $active
            Write-Host 'This patch is already installed and verified.'
            return
        }
        Write-Host 'Finishing the previous interrupted operation...'
        Restore-State $active
    }
    Write-Host '[1/4] Checking game and patch files...'
    Check-NewInstall $manifest
    $operationCount = @($manifest.operations).Count
    $state = [pscustomobject]@{format='koreanpatch-windows-v2/state-v1'; id=[Guid]::NewGuid().ToString('N'); game_root=$GameRoot; manifest_sha256=$manifestHash; manifest=$manifest; status='preparing'; created_dirs=@(); temp_files=@()}
    Save-Active $state
    try {
        $prepared = @{}
        $index = 0
        foreach ($op in @($manifest.operations)) {
            if (Is-Delta $op) {
                Assert-NoReparse $WorkRoot
                [IO.Directory]::CreateDirectory($WorkRoot) | Out-Null
                $work = [IO.Path]::Combine($WorkRoot, '.koreanpatch-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                $state.temp_files = @($state.temp_files) + @($work); Save-Active $state
                $target = Resolve-Relative $GameRoot ([string]$op.path) $true
                $payload = Resolve-Relative $PatchRoot ([string]$op.payload) $false
                Expand-Delta $target $payload $work ([long]$op.result_size)
                if ((Get-ShaFile $work) -ine [string]$op.after_sha256) { throw 'Delta result hash mismatch.' }
                $prepared[$index] = $work
            }
            $index++
        }
        Write-Host '[2/4] Backing up original files...'
        $index=0
        foreach ($op in @($manifest.operations)) {
            if ($op.kind -eq 'replace') {
                $target = Resolve-Relative $GameRoot ([string]$op.path) $true
                $backup = Backup-Path $state $index
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup)) | Out-Null
                [IO.File]::Copy($target,$backup,$false)
                if ((Get-ShaFile $backup) -ine [string]$op.before_sha256) { throw "Backup hash mismatch: $($op.path)" }
            }
            $index++
            Write-Count 'Files backed up:' $index $operationCount
        }
        $state.status='applying'; Save-Active $state
        Write-Host '[3/4] Applying patch files...'
        $done = 0
        foreach ($op in @($manifest.operations)) {
            $target = Resolve-Relative $GameRoot ([string]$op.path) $true
            $payload = Resolve-Relative $PatchRoot ([string]$op.payload) $false
            if (Is-Delta $op) { $payload = $prepared[$done] }
            Ensure-Parents $target $state
            Copy-IntoTarget $payload $target ([string]$op.after_sha256) ($op.kind -eq 'replace') $state
            $done++
            Write-Count 'Files applied:' $done $operationCount
        }
        Write-Host '[4/4] Verifying installed files...'
        Verify-Installed $state
        foreach ($work in $prepared.Values) { if ([IO.File]::Exists($work)) { [IO.File]::Delete($work) } }
        if ([IO.Directory]::Exists($WorkRoot) -and [IO.Directory]::GetFileSystemEntries($WorkRoot).Length -eq 0) { [IO.Directory]::Delete($WorkRoot,$false) }
        $state.status='installed'; Save-Active $state
        Write-Host 'Installation completed.'
    } catch {
        $reason = $_.Exception.Message
        try { Restore-State $state } catch { throw "Install failed: $reason. Rollback failed; backup and state retained: $($_.Exception.Message)" }
        throw "Install failed and changes were restored: $reason"
    }
}
function Restore-Patch {
    if ([IO.File]::Exists($ActivePath)) {
        $state = Read-State $ActivePath
        Restore-State $state
        Write-Host 'Restore and backup cleanup completed.'
    } elseif ([IO.File]::Exists($ReceiptPath)) {
        $receipt = Read-State $ReceiptPath
        Verify-Original $receipt
        Write-Host 'Already restored; original state verified.'
    } else {
        $manifest = Read-Json ([IO.Path]::Combine($PatchRoot,'manifest.json'))
        Check-Manifest $manifest
        Verify-Original ([pscustomobject]@{manifest=$manifest})
        Write-Host 'No active installation; original state verified.'
    }
}

$mutex=$null; $locked=$false
try {
    if ($GameRoot.StartsWith('\\')) { throw 'Unsupported game folder location. Put the game folder on a drive with a letter such as C:\; network and WSL paths that start with \\ are not supported. No game files were changed.' }
    Assert-NoReparse $GameRoot
    $rootBytes = [Text.Encoding]::UTF8.GetBytes($GameRoot.ToUpperInvariant())
    $lockName = 'Global\KoreanPatch-' + (Get-ShaBytes $rootBytes)
    $mutex = New-Object Threading.Mutex($false,$lockName)
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another KoreanPatch operation is running for this game folder.' }
    Write-Host 'WARNING: Close the game, launcher updates, mod managers, and programs that may change game files.'
    Write-Host 'Do not close this window or turn off the computer until the operation finishes.'
    $answer = Read-Host 'Continue? [y/N]'
    if ($answer -notmatch '^(?i:y|yes)$') { throw 'Cancelled; no game files were changed.' }
    if ($Action -eq 'install') { Install-Patch } else { Restore-Patch }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
