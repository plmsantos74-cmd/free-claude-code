param(
    [switch]$Force
)

$RepoDir = "C:\Users\eltho\free-claude-code"
$UvExe   = "C:\Users\eltho\.uv\uv.exe"
$WinSw   = "$RepoDir\free-claude-proxy-service.exe"
$SvcXml  = "$RepoDir\free-claude-proxy-service.xml"

# Rutas de los dos .env (el servicio corre como LocalSystem, solo lee el del proyecto)
$EnvProject = "$RepoDir\.env"
$EnvUser    = "$env:USERPROFILE\.fcc\.env"

Write-Output "============================================"
Write-Output "  Actualizando free-claude-code proxy..."
Write-Output "============================================"
Write-Output ""

# ---------------------------------------------------------------------------
# Función auxiliar: garantiza que una clave tenga el valor correcto en un .env
# ---------------------------------------------------------------------------
function Ensure-EnvValue {
    param(
        [string]$FilePath,
        [string]$Key,
        [string]$ExpectedValue,
        [string]$Label
    )
    if (-not (Test-Path $FilePath)) { return }
    $content = Get-Content $FilePath -Raw
    $pattern = "(?m)^($Key\s*=\s*)(.*)$"
    if ($content -match $pattern) {
        $current = ($content | Select-String -Pattern "(?m)^$Key\s*=\s*(.*)" | Select-Object -First 1).Matches.Groups[1].Value.Trim().Trim('"')
        if ($current -ne $ExpectedValue) {
            Write-Output "  ⚠️  $Label [$Key] era '$current' → corrigiendo a '$ExpectedValue'"
            $content = $content -replace "(?m)^($Key\s*=\s*).*$", "`${1}`"$ExpectedValue`""
            Set-Content $FilePath $content -NoNewline
        }
    }
}

# ---------------------------------------------------------------------------
# Función auxiliar: detecta qué proveedor/modelo está activo en el .env
# ---------------------------------------------------------------------------
function Get-ActiveProvider {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return "unknown" }
    $content = Get-Content $FilePath -Raw
    if ($content -match '(?m)^MODEL="([^"]+)"') {
        return $Matches[1].Split('/')[0]
    }
    return "unknown"
}

# ---------------------------------------------------------------------------
# Step 0: Verificar y corregir ajustes críticos ANTES del git pull
# ---------------------------------------------------------------------------
Write-Output "[0/4] Verificando configuración crítica..."

foreach ($envFile in @($EnvProject, $EnvUser)) {
    if (-not (Test-Path $envFile)) { continue }
    $label = if ($envFile -eq $EnvProject) { "proyecto" } else { "usuario (~/.fcc)" }

    # Thinking: siempre false
    Ensure-EnvValue $envFile "ENABLE_MODEL_THINKING"   "false" $label
    Ensure-EnvValue $envFile "ENABLE_OPUS_THINKING"    "false" $label
    Ensure-EnvValue $envFile "ENABLE_SONNET_THINKING"  "false" $label
    Ensure-EnvValue $envFile "ENABLE_HAIKU_THINKING"   "false" $label

    # Modelos DeepSeek inválidos conocidos
    $content = Get-Content $envFile -Raw
    $invalidModels = @('MODEL="deepseek/deepseek-v4-pro"', 'MODEL="deepseek/deepseek-ai/deepseek-v4-flash"')
    foreach ($invalid in $invalidModels) {
        if ($content -match [regex]::Escape($invalid)) {
            Write-Output "  ⚠️  $label [MODEL] inválido → corrigiendo a 'deepseek/deepseek-v4-flash'"
            $content = $content -replace [regex]::Escape($invalid), 'MODEL="deepseek/deepseek-v4-flash"'
            Set-Content $envFile $content -NoNewline
        }
    }

    # Modelos Gemini retirados → actualizar al modelo activo
    $retiredGemini = @('MODEL="gemini/gemini-2.0-flash"', 'MODEL="gemini/gemini-1.5-flash"')
    foreach ($retired in $retiredGemini) {
        $content = Get-Content $envFile -Raw
        if ($content -match [regex]::Escape($retired)) {
            Write-Output "  ⚠️  $label [MODEL] Gemini retirado → actualizando a 'gemini/gemini-2.5-flash'"
            $content = $content -replace [regex]::Escape($retired), 'MODEL="gemini/gemini-2.5-flash"'
            Set-Content $envFile $content -NoNewline
        }
    }
}

$activeProvider = Get-ActiveProvider $EnvProject
Write-Output "  ✅ Configuración crítica verificada. Proveedor activo: $activeProvider"
Write-Output ""

# ---------------------------------------------------------------------------
# Step 1: git pull (siempre desde main, tolera working tree sucio)
# ---------------------------------------------------------------------------
Write-Output "[1/4] Git pull..."
Set-Location $RepoDir
git checkout main 2>$null

# Stash automático si hay cambios locales sin commitear
$dirty = git status --porcelain --untracked-files=no
if ($dirty) {
    Write-Output "  ⚠️  Hay cambios locales sin commitear. Stashing temporalmente..."
    git stash push -m "auto-stash por update-proxy.ps1 (git pull)"
    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR: No se pudo hacer stash de los cambios locales."
        if (-not $Force) { exit 1 }
    }
    $stashed = $true
} else {
    $stashed = $false
}

git pull origin main
$pullOk = $LASTEXITCODE -eq 0

# Reaplicar stash si corresponde
if ($stashed) {
    Write-Output "  ⚠️  Reaplicando cambios locales (git stash pop)..."
    git stash pop
    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR: Conflicto al reaplicar cambios locales después del pull."
        Write-Output "       Resuélvelo manualmente y luego ejecuta: git stash drop"
        if (-not $Force) { exit 1 }
    }
}

if (-not $pullOk) {
    Write-Output "ERROR: git pull falló. Revisa conflictos manualmente."
    if (-not $Force) { exit 1 }
}

# ---------------------------------------------------------------------------
# Step 2: uv sync
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "[2/4] uv sync (actualizando dependencias)..."
& $UvExe sync
if ($LASTEXITCODE -ne 0) {
    Write-Output "ERROR: uv sync falló."
    if (-not $Force) { exit 1 }
}

# ---------------------------------------------------------------------------
# Step 3: Re-verificar ajustes críticos DESPUÉS del git pull
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "[3/4] Re-verificando configuración crítica post-pull..."

foreach ($envFile in @($EnvProject, $EnvUser)) {
    if (-not (Test-Path $envFile)) { continue }
    $label = if ($envFile -eq $EnvProject) { "proyecto" } else { "usuario (~/.fcc)" }
    Ensure-EnvValue $envFile "ENABLE_MODEL_THINKING"   "false" $label
    Ensure-EnvValue $envFile "ENABLE_OPUS_THINKING"    "false" $label
    Ensure-EnvValue $envFile "ENABLE_SONNET_THINKING"  "false" $label
    Ensure-EnvValue $envFile "ENABLE_HAIKU_THINKING"   "false" $label
    $content = Get-Content $envFile -Raw
    $invalidModels = @('MODEL="deepseek/deepseek-v4-pro"', 'MODEL="deepseek/deepseek-ai/deepseek-v4-flash"')
    foreach ($invalid in $invalidModels) {
        if ($content -match [regex]::Escape($invalid)) {
            $content = $content -replace [regex]::Escape($invalid), 'MODEL="deepseek/deepseek-v4-flash"'
            Set-Content $envFile $content -NoNewline
            Write-Output "  ⚠️  $label [MODEL] DeepSeek corregido post-pull."
        }
    }
    $retiredGemini = @('MODEL="gemini/gemini-2.0-flash"', 'MODEL="gemini/gemini-1.5-flash"')
    foreach ($retired in $retiredGemini) {
        $content = Get-Content $envFile -Raw
        if ($content -match [regex]::Escape($retired)) {
            $content = $content -replace [regex]::Escape($retired), 'MODEL="gemini/gemini-2.5-flash"'
            Set-Content $envFile $content -NoNewline
            Write-Output "  ⚠️  $label [MODEL] Gemini actualizado a 2.5-flash post-pull."
        }
    }
}
Write-Output "  ✅ Configuración crítica OK."
Write-Output ""

# ---------------------------------------------------------------------------
# Fix permanente: _strip_server_listed_tools en providers/deepseek/request.py
# El upstream aún no ha aceptado el PR #673 — reaplicamos tras cada pull.
# ---------------------------------------------------------------------------
$DeepseekReq = "$RepoDir\providers\deepseek\request.py"
$fixMarker   = "_strip_server_listed_tools"
$fixCode = @'

def _strip_server_listed_tools(data: dict[str, Any]) -> None:
    """Remove web_search / web_fetch tool definitions that DeepSeek cannot process.

    Newer Claude Code versions list these tools in every request. Stripping them
    silently (with a warning) keeps the request valid instead of failing outright.
    """
    tools = data.get("tools")
    if not isinstance(tools, list):
        return
    filtered = [t for t in tools if not (isinstance(t, dict) and _is_server_listed_tool(t))]
    dropped = len(tools) - len(filtered)
    if dropped:
        logger.warning(
            "DEEPSEEK_REQUEST: stripped {} unsupported server tool definition(s) "
            "(web_search / web_fetch).",
            dropped,
        )
        if filtered:
            data["tools"] = filtered
        else:
            data.pop("tools", None)


'@

$reqContent = Get-Content $DeepseekReq -Raw
if ($reqContent -notmatch [regex]::Escape($fixMarker)) {
    $reqContent = $reqContent -replace `
        '(def _validate_deepseek_native_request_dict)', `
        ($fixCode + '$1')
    $reqContent = $reqContent -replace `
        '(_strip_unsupported_attachment_blocks\(data\["messages"\]\)\s*\n\s*)(_validate_deepseek_native_request_dict)', `
        ('$1_strip_server_listed_tools(data)' + "`n    " + '$2')
    Set-Content $DeepseekReq $reqContent -NoNewline
    Write-Output "  ✅ Fix web tools reaplicado (PR #673 pendiente de merge)."
} else {
    Write-Output "  ✅ Fix web tools ya presente."
}
Write-Output ""

# ---------------------------------------------------------------------------
# Step 4: Reiniciar servicio
# ---------------------------------------------------------------------------
Write-Output "[4/4] Reiniciando servicio FreeClaudeProxy..."
& $WinSw stop $SvcXml
# Esperar hasta que el servicio esté completamente detenido (max 15s)
$waited = 0
do {
    Start-Sleep -Seconds 2
    $waited += 2
    $s = & $WinSw status $SvcXml 2>&1
} while ($s -ne "Stopped" -and $waited -lt 15)
& $WinSw start $SvcXml
Start-Sleep -Seconds 10

# ---------------------------------------------------------------------------
# Verificación final: health check + test de petición real
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "============================================"
$status = & $WinSw status $SvcXml 2>&1
if ($status -eq "Started") {
    $rootResp = curl.exe -s -m 10 http://localhost:8082/ -H "x-api-key: freecc" 2>&1
    $health   = curl.exe -s -m 10 http://localhost:8082/health 2>&1
    Write-Output "  ✅ Proxy actualizado y funcionando."
    Write-Output "  Health: $health"
    Write-Output "  Modelo activo: $rootResp"

    # Test real (timeout 45s para dar tiempo a DeepSeek)
    $testBody = '{"model":"claude-3-5-sonnet-20241022","max_tokens":30,"messages":[{"role":"user","content":"responde solo: ok"}]}'
    $testResp = curl.exe -s -m 45 -X POST "http://localhost:8082/v1/messages" `
        -H "x-api-key: freecc" -H "Content-Type: application/json" `
        -d $testBody 2>&1
    if ($testResp -match "message_stop") {
        Write-Output "  ✅ Test API: OK"
    } elseif ($testResp -match "Invalid request sent to provider") {
        Write-Output "  ❌ Test API: ERROR - modelo inválido o thinking activo"
        Write-Output "     → Verifica MODEL= y ENABLE_MODEL_THINKING=false en $EnvProject"
    } elseif ($testResp -match '"type":\s*"error"') {
        Write-Output "  ❌ Test API: ERROR - $testResp"
    } else {
        Write-Output "  ⚠️  Test API: sin respuesta o timeout ($(Get-Date -Format 'HH:mm:ss'))"
    }
} else {
    Write-Output "  ⚠️  Servicio no inició. Revisa logs:"
    Write-Output "     $RepoDir\free-claude-proxy-service.0.out.log"
    Write-Output "     $RepoDir\free-claude-proxy-service.0.err.log"
}
Write-Output "============================================"
