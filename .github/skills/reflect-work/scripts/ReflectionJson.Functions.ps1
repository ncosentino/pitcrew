#Requires -Version 7.0
<#
.SYNOPSIS
    Dot-sourced library for bounded, schema-checked reflection evidence.
.DESCRIPTION
    Defines read-only helpers. Preserves JSON strings/nulls, rejects duplicate keys,
    and binds the parsed value to the exact input bytes. No top-level I/O.
#>

function ConvertFrom-ReflectionJsonElement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $value = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if ($value.ContainsKey($property.Name)) { throw 'Duplicate JSON property in reflection evidence.' }
                $value.Add($property.Name, (ConvertFrom-ReflectionJsonElement -Element $property.Value))
            }
            return ,$value
        }
        'Array' {
            $value = [Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) {
                $value.Add((ConvertFrom-ReflectionJsonElement -Element $item))
            }
            return ,$value.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' { return $Element.GetDecimal() }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        default { throw 'Unsupported JSON value in reflection evidence.' }
    }
}

function Read-ReflectionJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SchemaPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SchemaLabel,
        [Parameter(Mandatory)][ValidateRange(1, 2097152)][int]$MaxBytes,
        [ValidateRange(1, 32)][int]$MaxDepth = 16
    )

    $stream = $null
    try {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        if ($resolved.StartsWith('\\') -or $resolved.StartsWith('//')) {
            throw 'Reflection evidence cannot be read from a network path.'
        }
        $current = [IO.Path]::GetPathRoot($resolved)
        $relative = [IO.Path]::GetRelativePath($current, $resolved)
        foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar)) {
            $current = Join-Path $current $part
            $entry = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Reflection evidence cannot traverse a link or reparse point.'
            }
        }
        $file = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Reflection evidence must be a regular file, not a directory or link.'
        }
        $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt $MaxBytes) { throw "Reflection input exceeds the $MaxBytes byte limit." }
        $buffer = [byte[]]::new($MaxBytes + 1)
        $length = 0
        while ($length -lt $buffer.Length) {
            $read = $stream.Read($buffer, $length, $buffer.Length - $length)
            if ($read -eq 0) { break }
            $length += $read
        }
        if ($length -gt $MaxBytes) { throw "Reflection input exceeds the $MaxBytes byte limit." }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $length)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($buffer, 0, $length)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($text.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) {
            $text = $text.Substring(1)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = $MaxDepth
        try { $document = [System.Text.Json.JsonDocument]::Parse($text, $options) }
        catch [System.Text.Json.JsonException] {
            throw "Reflection input has invalid JSON syntax or exceeds maximum nesting depth of $MaxDepth."
        }
        $value = ConvertFrom-ReflectionJsonElement -Element $document.RootElement
        if (-not (Test-Json -Json $text -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
            throw "Reflection input violates the closed $SchemaLabel schema."
        }
        return [PSCustomObject]@{ Value = $value; Sha256 = $hash; ByteCount = $length }
    } finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}
