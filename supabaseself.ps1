# supabaseself.ps1 -- CLI para deploy de edge functions e migrations no Supabase self-hosted
param(
    [Parameter(Position=0)] [string]$Command,
    [Parameter(Position=1)] [string]$SubCommand,
    [Parameter(Position=2)] [string]$Arg1,
    [string]$ServerHost,
    [string]$Key,
    [string]$Dir           = "supabase/functions",
    [string]$MigrationsDir = "supabase/migrations",
    # db dump
    [string]$Output  = "",          # arquivo de saida local
    [string]$Format  = "plain",     # plain | custom | tar
    [string[]]$Tables         = @(),
    [string[]]$Schemas        = @(),
    [string[]]$ExcludeTables  = @(),
    [switch]$SchemaOnly,
    [switch]$DataOnly,
    [switch]$NoOwner,
    [switch]$NoAcl,
    [string[]]$ExtraArgs = @(),
    # dump-view / dump-grep
    [int]$Lines    = 100,
    [string]$Pattern = "",
    # db exec
    [switch]$IgnoreErrors   # nao para no primeiro erro (util para restores de dump)
)

$ErrorActionPreference = "Stop"
# $HOME é variável automática do PowerShell (Windows e cross-platform);
# $env:USERPROFILE só existe no Windows e fica vazio no pwsh do macOS/Linux,
# quebrando o caminho do arquivo de config nesses ambientes.
$CONFIG_FILE = Join-Path $HOME ".supabaseself.ps1"

function Info($msg)    { Write-Host "  $msg" -ForegroundColor Cyan }
function Ok($msg)      { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg)    { Write-Host "  $msg" -ForegroundColor Yellow }
function Err($msg)     { Write-Host "  $msg" -ForegroundColor Red }
function Die($msg)     { Err $msg; exit 1 }

function Load-Config {
    if (Test-Path $CONFIG_FILE) {
        . $CONFIG_FILE
        if (-not $script:ServerHost -and $env:SUPABASESELF_HOST) { $script:ServerHost = $env:SUPABASESELF_HOST }
        if (-not $script:Key        -and $env:SUPABASESELF_KEY)  { $script:Key        = $env:SUPABASESELF_KEY  }
    }
}

function Save-Config {
    Set-Content $CONFIG_FILE -Encoding UTF8 -Value ("`$env:SUPABASESELF_HOST = `"" + $script:ServerHost + "`"`n`$env:SUPABASESELF_KEY  = `"" + $script:Key + "`"")
    Ok "Configuracao salva em $CONFIG_FILE"
}

function Resolve-Credentials {
    Load-Config
    if (-not $script:ServerHost) { $script:ServerHost = Read-Host "  Host (ex: https://api-pgf.prodesp.sp.gov.br)" }
    if (-not $script:Key)        { $script:Key        = Read-Host "  Chave de deploy (DEPLOY_KEY)" }
    $script:ServerHost = $script:ServerHost.Trim().TrimEnd("/")
    $script:Key        = $script:Key.Trim()
}

function Check-Health {
    try {
        $resp = Invoke-RestMethod -Uri "$($script:ServerHost)/deploy/health" -TimeoutSec 10
        Info "Deploy service OK - $($resp.timestamp)"
    } catch {
        Die "Nao foi possivel alcançar $($script:ServerHost)/deploy/health"
    }
}

function Send-ZipFile([string]$Uri, [string]$FilePath) {
    $boundary  = [System.Guid]::NewGuid().ToString()
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $fileName  = [System.IO.Path]::GetFileName($FilePath)
    $parts     = [System.Collections.Generic.List[byte]]::new()
    $header    = "--$boundary`r`nContent-Disposition: form-data; name=`"bundle`"; filename=`"$fileName`"`r`nContent-Type: application/zip`r`n`r`n"
    $parts.AddRange([System.Text.Encoding]::UTF8.GetBytes($header))
    $parts.AddRange($fileBytes)
    $parts.AddRange([System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n"))
    return Invoke-RestMethod -Uri $Uri -Method POST `
        -Headers @{ "X-Deploy-Key" = $script:Key } `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $parts.ToArray() -TimeoutSec 300
}

function Cmd-FunctionsDeploy {
    Resolve-Credentials
    if (-not (Test-Path $Dir)) { Die "Diretorio nao encontrado: $Dir" }
    Check-Health
    $tmp = [System.IO.Path]::GetTempFileName() -replace "\.tmp$",".zip"
    if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) }
    Info "Empacotando $Dir/ ..."
    Compress-Archive -Path "$Dir/*" -DestinationPath $tmp -Force
    Info ("Bundle: {0:N0} KB" -f ((Get-Item $tmp).Length/1KB))
    try {
        $r = Send-ZipFile -Uri "$($script:ServerHost)/deploy/functions" -FilePath $tmp
        Ok "Deploy concluido! $($r.files) arquivos. Container reiniciado."
    } catch { Die "Falha: $_`n$($_.ErrorDetails.Message)" }
    finally  { if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) } }
}

function Cmd-FunctionsLogs {
    Resolve-Credentials
    Check-Health

    $funcName  = $Arg1
    $qs        = if ($funcName) { "?func=$([Uri]::EscapeDataString($funcName))" } else { "" }
    $streamUri = "$($script:ServerHost)/deploy/functions/logs/stream$qs"

    if ($funcName) { Info "Logs de `"$funcName`" em tempo real. Ctrl+C para parar.`n" }
    else           { Info "Logs de todas as functions. Ctrl+C para parar.`n" }

    try {
        $req = [System.Net.HttpWebRequest]::Create($streamUri)
        $req.Method = "GET"
        $req.Headers.Add("X-Deploy-Key", $script:Key)
        $req.Timeout = -1
        $req.ReadWriteTimeout = -1

        $resp   = $req.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)

        # Usa ReadLineAsync + polling de 100 ms para que Ctrl+C interrompa normalmente
        try {
            while ($true) {
                $task = $reader.ReadLineAsync()
                while (-not $task.IsCompleted) {
                    Start-Sleep -Milliseconds 100
                }
                if ($task.IsFaulted -or $task.Result -eq $null) { break }
                $raw = $task.Result
                if ($raw -match "^data: `"(.+)`"$") {
                    $msg = $Matches[1] -replace "\\n","`n" -replace "\\`"","`"" -replace "\\\\","\"
                    Write-Host $msg
                } elseif ($raw -match "stream ended") {
                    break
                }
            }
        } finally {
            try { $req.Abort() }  catch {}
            try { $reader.Close() } catch {}
        }
    } catch {
        Warn "Stream indisponivel. Buscando ultimas 200 linhas..."
        try {
            $r = Invoke-RestMethod -Uri "$($script:ServerHost)/deploy/functions/logs$qs" `
                -Headers @{ "X-Deploy-Key" = $script:Key } -TimeoutSec 30
            Info "$($r.count) linha(s):"
            $r.lines | ForEach-Object { Write-Host $_ }
        } catch { Die "Falha: $_" }
    }
}

function Cmd-DbExec {
    Resolve-Credentials
    if (-not $Arg1) { Die "Informe o arquivo .sql. Ex: db exec script.sql" }
    if (-not (Test-Path $Arg1)) { Die "Arquivo nao encontrado: $Arg1" }
    Check-Health

    $filePath  = (Resolve-Path $Arg1).Path
    $fileName  = [System.IO.Path]::GetFileName($filePath)
    $fileSize  = (Get-Item $filePath).Length
    $boundary  = [System.Guid]::NewGuid().ToString()
    $enc       = [System.Text.Encoding]::UTF8

    # Cabecalho e rodape multipart (sem carregar o arquivo em memoria)
    $headerBytes = $enc.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"sql`"; filename=`"$fileName`"`r`nContent-Type: text/plain`r`n`r`n")
    $footerBytes = $enc.GetBytes("`r`n--$boundary--`r`n")
    $totalLength = $headerBytes.Length + $fileSize + $footerBytes.Length

    Info "Enviando $fileName ($([math]::Round($fileSize/1MB,1)) MB) para execucao..."

    $streamUri = "$($script:ServerHost)/deploy/db/exec$(if ($IgnoreErrors) { '?ignore_errors=1' } else { '' })"
    try {
        $req = [System.Net.HttpWebRequest]::Create($streamUri)
        $req.Method          = "POST"
        $req.Headers.Add("X-Deploy-Key", $script:Key)
        $req.ContentType     = "multipart/form-data; boundary=$boundary"
        $req.ContentLength   = $totalLength
        $req.Timeout         = -1
        $req.ReadWriteTimeout = -1
        $req.AllowWriteStreamBuffering = $false   # nao bufferiza — critico para arquivos grandes

        # Upload em streaming: header + arquivo (chunks de 1 MB) + footer
        $reqStream = $req.GetRequestStream()
        $reqStream.Write($headerBytes, 0, $headerBytes.Length)

        $fileStream = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $buf = New-Object byte[] (1MB)
        $sent = 0
        try {
            while ($true) {
                $n = $fileStream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $reqStream.Write($buf, 0, $n)
                $sent += $n
                $pct = [math]::Round($sent * 100 / $fileSize)
                Write-Host -NoNewline "`r  Upload: $pct% ($([math]::Round($sent/1MB,1)) / $([math]::Round($fileSize/1MB,1)) MB)  "
            }
        } finally {
            $fileStream.Close()
        }
        Write-Host ""  # nova linha apos progress

        $reqStream.Write($footerBytes, 0, $footerBytes.Length)
        $reqStream.Close()

        Info "Upload concluido. Aguardando execucao no banco (pode demorar para arquivos grandes)..."

        $resp   = $req.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), $enc)
        $exitCode = 0
        try {
            while ($true) {
                $task = $reader.ReadLineAsync()
                while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 100 }
                if ($task.IsFaulted -or $task.Result -eq $null) { break }
                $raw = $task.Result
                if ($raw -match '^data: \{"__exit":(-?\d+)\}') {
                    $exitCode = [int]$Matches[1]; break
                } elseif ($raw -match '^data: "(.+)"$') {
                    $line = $Matches[1] -replace '\\n',"`n" -replace '\\"','"' -replace '\\\\','\'
                    Write-Host $line
                }
            }
        } finally {
            try { $req.Abort() } catch {}
            try { $reader.Close() } catch {}
        }
        if ($exitCode -eq 0) { Ok "Execucao concluida com sucesso." }
        else                  { Die "psql encerrou com codigo $exitCode (erro ou sinal)." }
    } catch { Die "Falha: $_" }
}

function Assert-DumpFile {
    if (-not $Arg1)              { Die "Informe o arquivo. Ex: db dump-head backup.sql" }
    if (-not (Test-Path $Arg1))  { Die "Arquivo nao encontrado: $Arg1" }
    return [System.IO.Path]::GetFullPath($Arg1)
}

# ── db dump-head — primeiras N linhas ────────────────────────────────────────
function Cmd-DbDumpHead {
    $file = Assert-DumpFile
    $n    = $Lines
    Info "Primeiras $n linhas de $file"
    Write-Host ""
    $i = 0
    $reader = [System.IO.StreamReader]::new($file, [System.Text.Encoding]::UTF8)
    try {
        while ($i -lt $n) {
            $line = $reader.ReadLine()
            if ($line -eq $null) { break }
            Write-Host $line
            $i++
        }
    } finally { $reader.Close() }
    Write-Host ""
    Info "$i linha(s) exibida(s)."
}

# ── db dump-tail — ultimas N linhas ──────────────────────────────────────────
function Cmd-DbDumpTail {
    $file = Assert-DumpFile
    $n    = $Lines
    Info "Ultimas $n linhas de $file"
    Write-Host ""
    # Lê em blocos do fim do arquivo sem carregar tudo na memoria
    $fstream = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $buf     = [byte[]]::new(1MB)
        $queue   = [System.Collections.Generic.Queue[string]]::new()
        $leftover= ""
        $pos     = $fstream.Length

        while ($queue.Count -lt $n -and $pos -gt 0) {
            $read = [Math]::Min($buf.Length, $pos)
            $pos -= $read
            $fstream.Seek($pos, [System.IO.SeekOrigin]::Begin) | Out-Null
            $fstream.Read($buf, 0, $read) | Out-Null
            $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
            $combined = $chunk + $leftover
            $parts = $combined -split "`n"
            $leftover = $parts[0]
            for ($j = $parts.Count - 1; $j -ge 1; $j--) { $queue.Enqueue($parts[$j]) }
        }
        if ($leftover) { $queue.Enqueue($leftover) }
        $lines = @($queue) | Select-Object -Last $n
        $lines | ForEach-Object { Write-Host $_ }
    } finally { $fstream.Close() }
    Write-Host ""
    Info "Fim do arquivo."
}

# ── db dump-tables — lista tabelas no dump ───────────────────────────────────
function Cmd-DbDumpTables {
    $file = Assert-DumpFile
    Info "Tabelas encontradas em $file :"
    Write-Host ""
    $reader = [System.IO.StreamReader]::new($file, [System.Text.Encoding]::UTF8)
    $tables = [System.Collections.Generic.SortedSet[string]]::new()
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($line -eq $null) { break }
            # CREATE TABLE public.nome  ou  COPY public.nome
            if ($line -match '^\s*CREATE TABLE\s+(?:\w+\.)?(\w+)') {
                $tables.Add("TABLE  $($Matches[1])") | Out-Null
            } elseif ($line -match '^\s*CREATE(?:\s+UNLOGGED)?\s+TABLE\s+(?:\w+\.)?(\w+)') {
                $tables.Add("TABLE  $($Matches[1])") | Out-Null
            } elseif ($line -match '^\s*COPY\s+(?:\w+\.)?(\w+)\s+\(') {
                $tables.Add("DATA   $($Matches[1])") | Out-Null
            } elseif ($line -match '^-- Name:\s+(\w+);\s+Type:\s+(\w+)') {
                if ($Matches[2] -in @("TABLE","SEQUENCE","INDEX","CONSTRAINT","TRIGGER","FUNCTION","VIEW","TYPE")) {
                    $tables.Add("$($Matches[2].PadRight(12))$($Matches[1])") | Out-Null
                }
            }
        }
    } finally { $reader.Close() }
    $tables | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Info "$($tables.Count) objeto(s) encontrado(s)."
}

# ── db dump-grep — busca padrao no arquivo ───────────────────────────────────
function Cmd-DbDumpGrep {
    $file = Assert-DumpFile
    if (-not $Pattern) { Die "Informe o padrao. Ex: db dump-grep backup.sql -Pattern 'CREATE TABLE'" }
    Info "Buscando '$Pattern' em $file (max $Lines ocorrencias)..."
    Write-Host ""
    $reader  = [System.IO.StreamReader]::new($file, [System.Text.Encoding]::UTF8)
    $count   = 0
    $lineNum = 0
    $max     = $Lines
    try {
        while ($count -lt $max) {
            $line = $reader.ReadLine()
            if ($line -eq $null) { break }
            $lineNum++
            if ($line -match $Pattern) {
                Write-Host ("{0,8}: {1}" -f $lineNum, $line)
                $count++
            }
        }
    } finally { $reader.Close() }
    Write-Host ""
    if ($count -eq $max) { Warn "Limite de $max resultados atingido. Use -Lines N para mais." }
    else                 { Info "$count ocorrencia(s) encontrada(s)." }
}

function Cmd-DbDumpTest {
    Resolve-Credentials
    Check-Health
    try {
        $r = Invoke-RestMethod -Uri "$($script:ServerHost)/deploy/db/tools" `
            -Headers @{ "X-Deploy-Key" = $script:Key } -TimeoutSec 15
        Info "psql:    $($r.psql.out)"
        Info "pg_dump: $($r.pg_dump.out)"
        if ($r.db.ok) { Ok  "Conexao DB: OK`n  $($r.db.out)" }
        else          { Err "Conexao DB: FALHOU`n  $($r.db.err)" }
    } catch { Die "Falha: $_" }
}

function Cmd-DbDump {
    Resolve-Credentials
    Check-Health

    # monta body JSON
    $body = @{ format = $Format }
    if ($SchemaOnly)                 { $body.schema_only   = $true }
    if ($DataOnly)                   { $body.data_only     = $true }
    if ($NoOwner)                    { $body.no_owner      = $true }
    if ($NoAcl)                      { $body.no_acl        = $true }
    if ($Tables.Count -gt 0)        { $body.tables         = $Tables }
    if ($Schemas.Count -gt 0)       { $body.schemas        = $Schemas }
    if ($ExcludeTables.Count -gt 0) { $body.exclude_tables = $ExcludeTables }
    if ($ExtraArgs.Count -gt 0)     { $body.extra_args     = $ExtraArgs }

    $ext        = if ($Format -eq "custom") { "dump" } elseif ($Format -eq "tar") { "tar" } else { "sql" }
    $defaultOut = "dump_$(Get-Date -Format 'yyyyMMdd_HHmmss').$ext"
    $outFile    = if ($Output) { $Output } else { $defaultOut }
    $outFileFull = [System.IO.Path]::GetFullPath($outFile)

    Info "Iniciando dump (formato: $Format)..."

    # ── Fase 1: POST SSE — acompanha progresso do pg_dump no servidor ──────────
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $body -Compress))
    $req = [System.Net.HttpWebRequest]::Create("$($script:ServerHost)/deploy/db/dump")
    $req.Method = "POST"
    $req.Headers.Add("X-Deploy-Key", $script:Key)
    $req.ContentType = "application/json"
    $req.Timeout = -1
    $req.ReadWriteTimeout = -1
    $req.ContentLength = $jsonBytes.Length
    $rs = $req.GetRequestStream(); $rs.Write($jsonBytes, 0, $jsonBytes.Length); $rs.Close()

    $jobId = $null
    $srvFilename = $null
    $srvSize = 0

    try {
        $resp   = $req.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try {
            while ($true) {
                $task = $reader.ReadLineAsync()
                while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 100 }
                if ($task.IsFaulted -or $task.Result -eq $null) { break }
                $raw = $task.Result
                if ($raw -notmatch '^data: ') { continue }
                $json = $raw -replace '^data: ',''
                try { $evt = ConvertFrom-Json $json } catch { continue }
                switch ($evt.status) {
                    "running" { Info $evt.msg }
                    "done"    {
                        $jobId       = $evt.jobId
                        $srvFilename = $evt.filename
                        $srvSize     = $evt.size
                        Ok "pg_dump concluido no servidor ($([math]::Round($srvSize/1MB,2)) MB)"
                        break
                    }
                    "error"   { Die "Erro no servidor: $($evt.error)" }
                }
                if ($jobId) { break }
            }
        } finally {
            try { $req.Abort() } catch {}
            try { $reader.Close() } catch {}
        }
    } catch [System.Net.WebException] {
        $errResp = $_.Exception.Response
        if ($errResp) {
            $errBody = [System.IO.StreamReader]::new($errResp.GetResponseStream()).ReadToEnd()
            Die "Erro do servidor: $errBody"
        }
        Die "Falha: $_"
    }

    if (-not $jobId) { Die "Nao foi possivel obter jobId do servidor." }

    # ── Fase 2: GET download do arquivo ────────────────────────────────────────
    Info "Baixando $srvFilename -> $outFileFull ..."

    $dlReq = [System.Net.HttpWebRequest]::Create("$($script:ServerHost)/deploy/db/dump/$jobId")
    $dlReq.Method = "GET"
    $dlReq.Headers.Add("X-Deploy-Key", $script:Key)
    $dlReq.Timeout = -1
    $dlReq.ReadWriteTimeout = -1

    try { $dlResp = $dlReq.GetResponse() }
    catch [System.Net.WebException] {
        $errBody = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()).ReadToEnd()
        Die "Erro no download: $errBody"
    }

    $dlStream = $dlResp.GetResponseStream()
    $out      = [System.IO.FileStream]::new($outFileFull, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $buf      = [byte[]]::new(64 * 1024)
    $total    = 0
    try {
        while ($true) {
            $n = $dlStream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $total += $n
            $pct = if ($srvSize -gt 0) { [int]($total * 100 / $srvSize) } else { "?" }
            Write-Host -NoNewline "`r  Baixado: $([math]::Round($total/1MB,2)) MB  ($pct%)   "
        }
    } finally {
        $out.Close()
        $dlStream.Close()
    }

    Write-Host ""
    if ($total -eq 0) {
        if (Test-Path $outFileFull) { [System.IO.File]::Delete($outFileFull) }
        Die "Arquivo vazio recebido."
    }
    Ok "Dump salvo: $outFileFull ($([math]::Round($total/1MB,2)) MB)"
}

function Cmd-FunctionsSetEnv {
    Resolve-Credentials
    if (-not $Arg1)          { Die "Informe KEY=VALUE. Ex: functions set-env MINHA_VAR=valor" }
    if ($Arg1 -notmatch "=") { Die "Formato invalido. Use KEY=VALUE" }
    Check-Health
    $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ pairs = @($Arg1) } -Compress))
    try {
        $r = Invoke-RestMethod -Uri "$($script:ServerHost)/deploy/functions/env" -Method POST `
            -Headers @{ "X-Deploy-Key" = $script:Key; "Content-Type" = "application/json" } `
            -Body $body -TimeoutSec 30
        foreach ($c in $r.changed) { Ok "$($c.action.ToUpper())  $($c.key)" }
        Ok "Container reiniciado."
    } catch { Die "Falha: $_`n$($_.ErrorDetails.Message)" }
}

function Cmd-FunctionsGetEnv {
    Resolve-Credentials
    Check-Health
    if ($Arg1) {
        try {
            $r = Invoke-RestMethod `
                -Uri "$($script:ServerHost)/deploy/functions/env/$([Uri]::EscapeDataString($Arg1))" `
                -Headers @{ "X-Deploy-Key" = $script:Key } -TimeoutSec 15
            Write-Host "$($r.key)=$($r.value)"
        } catch { Die "Chave nao encontrada: $Arg1" }
    } else {
        try {
            $r = Invoke-RestMethod -Uri "$($script:ServerHost)/deploy/functions/env" `
                -Headers @{ "X-Deploy-Key" = $script:Key } -TimeoutSec 15
            Info "$($r.count) variavel(is) -- valores mascarados:"
            $r.vars.PSObject.Properties | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name)=$($_.Value)" }
        } catch { Die "Falha: $_" }
    }
}

function Cmd-FunctionsDeleteEnv {
    Resolve-Credentials
    if (-not $Arg1) { Die "Informe o nome da variavel. Ex: functions delete-env MINHA_VAR" }
    Check-Health
    try {
        $r = Invoke-RestMethod `
            -Uri "$($script:ServerHost)/deploy/functions/env/$([Uri]::EscapeDataString($Arg1))" `
            -Method DELETE -Headers @{ "X-Deploy-Key" = $script:Key } -TimeoutSec 30
        Ok "Deletada: $($r.deleted). Container reiniciado."
    } catch { Die "Falha: $_`n$($_.ErrorDetails.Message)" }
}

function Cmd-DbPush {
    Resolve-Credentials
    if (-not (Test-Path $MigrationsDir)) { Die "Diretorio nao encontrado: $MigrationsDir" }
    Check-Health
    $tmp = [System.IO.Path]::GetTempFileName() -replace "\.tmp$",".zip"
    if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) }
    Info "Empacotando migrations de $MigrationsDir/ ..."
    Compress-Archive -Path "$MigrationsDir/*.sql" -DestinationPath $tmp -Force
    Info ("Bundle: {0:N0} KB" -f ((Get-Item $tmp).Length/1KB))
    try {
        $r = Send-ZipFile -Uri "$($script:ServerHost)/deploy/db/push" -FilePath $tmp
        $applied = 0; $skipped = 0; $errors = 0
        foreach ($m in $r.results) {
            switch ($m.status) {
                "applied" { Ok  "APPLIED  $($m.name)"; $applied++ }
                "skipped" { $skipped++ }
                "error"   { Err "ERROR    $($m.name) - $($m.error)"; $errors++ }
            }
        }
        Write-Host ""
        Info "Resultado: $applied aplicadas, $skipped ignoradas, $errors erros."
        if ($errors -gt 0) { Die "$errors migration(s) falharam." }
        Ok "Concluido."
    } catch { Die "Falha: $_`n$($_.ErrorDetails.Message)" }
    finally  { if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) } }
}

function Cmd-DbBaseline {
    Resolve-Credentials
    if (-not (Test-Path $MigrationsDir)) { Die "Diretorio nao encontrado: $MigrationsDir" }
    Check-Health
    Warn "BASELINE: marcando todas as migrations como aplicadas SEM executar o SQL."
    Info "Para cancelar, pressione Ctrl+C. Continuando em 3 segundos..."
    Start-Sleep -Seconds 3
    $tmp = [System.IO.Path]::GetTempFileName() -replace "\.tmp$",".zip"
    if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) }
    Info "Empacotando migrations ..."
    Compress-Archive -Path "$MigrationsDir/*.sql" -DestinationPath $tmp -Force
    try {
        $r = Send-ZipFile -Uri "$($script:ServerHost)/deploy/db/baseline" -FilePath $tmp
        Ok "Baseline concluido: $($r.marked) marcadas, $($r.skipped) ja existiam."
    } catch { Die "Falha: $_`n$($_.ErrorDetails.Message)" }
    finally  { if (Test-Path $tmp) { [System.IO.File]::Delete($tmp) } }
}

function Cmd-DbStatus {
    Resolve-Credentials
    Check-Health
    try {
        $r = Invoke-RestMethod -Uri "$($script:ServerHost)/deploy/db/status" `
            -Headers @{ "X-Deploy-Key" = $script:Key } -TimeoutSec 30
        Info "$($r.applied.Count) migration(s) aplicada(s):"
        $r.applied | ForEach-Object {
            $ts = $_.applied_at
            $tsStr = if ($ts -is [string]) { $ts.Substring(0, [Math]::Min(19, $ts.Length)) } else { $ts.ToString("yyyy-MM-ddTHH:mm:ss") }
            Write-Host "    $tsStr  $($_.name)"
        }
    } catch { Die "Falha: $_" }
}

function Cmd-Config {
    $cliServerHost = $ServerHost
    $cliKey        = $Key
    Load-Config
    Write-Host "`nConfigurar credenciais padrao (salvas em $CONFIG_FILE)" -ForegroundColor White
    if ($cliServerHost) {
        $script:ServerHost = $cliServerHost
    } else {
        $h = (Read-Host "  Host [$($script:ServerHost)]").Trim()
        if ($h) { $script:ServerHost = $h }
    }
    if ($cliKey) {
        $script:Key = $cliKey
    } else {
        $k = (Read-Host "  Chave de deploy").Trim()
        if ($k) { $script:Key = $k }
    }
    Save-Config
}

function Cmd-DockerPullRestart {
    Resolve-Credentials
    if (-not $Arg1) { Die "Informe o nome do servico. Ex: docker pull-restart extrato-export-worker" }
    Check-Health
    $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json @{ service = $Arg1 } -Compress))
    $uri  = "$($script:ServerHost)/deploy/docker/pull-restart"

    Info "Iniciando docker pull + restart para '$Arg1'..."
    try {
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method = "POST"
        $req.Headers.Add("X-Deploy-Key", $script:Key)
        $req.ContentType = "application/json"
        $req.Timeout = -1
        $req.ReadWriteTimeout = -1
        $reqStream = $req.GetRequestStream()
        $reqStream.Write($body, 0, $body.Length)
        $reqStream.Close()

        $resp   = $req.GetResponse()
        $reader = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $exit   = $null
        try {
            while ($true) {
                $task = $reader.ReadLineAsync()
                while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 100 }
                if ($task.IsFaulted -or $task.Result -eq $null) { break }
                $raw = $task.Result
                if ($raw -match "^data: `"(.+)`"$") {
                    $msg = $Matches[1] -replace "\\n","`n" -replace "\\`"","`"" -replace "\\\\","\"
                    Write-Host "  $msg"
                } elseif ($raw -match "^data: (\{.+\})$") {
                    try {
                        $obj  = $Matches[1] | ConvertFrom-Json
                        $exit = $obj.__exit
                    } catch {}
                }
            }
        } finally { $reader.Close() }

        if ($exit -eq 0) { Ok "Servico '$Arg1' atualizado com sucesso." }
        else             { Die "Falha ao atualizar '$Arg1'." }
    } catch { Die "Falha: $_" }
}

function Show-Usage {
    Write-Host @"

supabaseself.ps1 - Deploy CLI para Supabase self-hosted

Comandos:
  functions deploy           Empacota supabase/functions/ e deploya
  functions logs [FUNC]      Stream de logs em tempo real (sem FUNC = todos)
  functions set-env K=V      Cria ou altera variavel de ambiente
  functions get-env [KEY]    Le variavel (sem KEY = lista todas mascaradas)
  functions delete-env KEY   Remove variavel de ambiente
  db push                    Aplica migrations pendentes
  db baseline                Marca migrations como aplicadas sem executar SQL
  db status                  Lista migrations aplicadas no servidor
  db exec <arquivo.sql>      Executa arquivo SQL no banco (qualquer tamanho)
  db dump                    Gera pg_dump e baixa o arquivo localmente
  db dump-test               Verifica psql/pg_dump e conexao com o banco
  db dump-head <arquivo>     Primeiras N linhas do dump  [-Lines N, padrao 100]
  db dump-tail <arquivo>     Ultimas N linhas do dump    [-Lines N, padrao 100]
  db dump-tables <arquivo>   Lista tabelas/objetos no dump
  db dump-grep <arquivo>     Busca padrao no dump  -Pattern "regex" [-Lines max]
  docker pull-restart SERVICO  Faz docker compose pull + up -d no servico informado
  config                     Salva credenciais em ~/.supabaseself.ps1

Opcoes gerais:
  -ServerHost HOST     URL base (ex: https://api-pgf.prodesp.sp.gov.br)
  -Key KEY             Chave de deploy
  -Dir DIR             Diretorio de functions  [padrao: supabase/functions]
  -MigrationsDir DIR   Diretorio de migrations [padrao: supabase/migrations]

Opcoes de db dump:
  -Output ARQUIVO      Nome do arquivo de saida  [padrao: dump_YYYYMMDD_HHmmss.sql]
  -Format plain|custom|tar   Formato do dump      [padrao: plain]
  -Tables t1,t2        Apenas estas tabelas
  -Schemas s1,s2       Apenas estes schemas
  -ExcludeTables t1    Excluir tabelas
  -SchemaOnly          So estrutura (sem dados)
  -DataOnly            So dados (sem estrutura)
  -NoOwner             Sem comandos ALTER OWNER
  -NoAcl               Sem comandos GRANT/REVOKE
  -ExtraArgs a1,a2     Args extras para pg_dump

Exemplos:
  .\supabaseself.ps1 functions logs govbr-auth-url
  .\supabaseself.ps1 functions deploy
  .\supabaseself.ps1 functions set-env RESEND_API_KEY=re_abc123
  .\supabaseself.ps1 db push
  .\supabaseself.ps1 db exec correcao.sql
  .\supabaseself.ps1 db dump
  .\supabaseself.ps1 db dump -Output backup.sql -NoOwner -NoAcl
  .\supabaseself.ps1 db dump -Format custom -Output backup.dump
  .\supabaseself.ps1 db dump -Tables users,contracts -SchemaOnly
  .\supabaseself.ps1 db dump -Format custom -Output prod.dump -NoOwner
  .\supabaseself.ps1 db dump-head .\backup_prod.sql -Lines 200
  .\supabaseself.ps1 db dump-tables .\backup_prod.sql
  .\supabaseself.ps1 db dump-grep .\backup_prod.sql -Pattern "CREATE TABLE.*usuario"
  .\supabaseself.ps1 db dump-grep .\backup_prod.sql -Pattern "INSERT INTO contratos" -Lines 50
  .\supabaseself.ps1 docker pull-restart extrato-export-worker

"@
}

switch ("$Command $SubCommand".Trim()) {
    "functions deploy"     { Cmd-FunctionsDeploy    }
    "functions logs"       { Cmd-FunctionsLogs      }
    "functions set-env"    { Cmd-FunctionsSetEnv    }
    "functions get-env"    { Cmd-FunctionsGetEnv    }
    "functions delete-env" { Cmd-FunctionsDeleteEnv }
    "db push"              { Cmd-DbPush             }
    "db baseline"          { Cmd-DbBaseline         }
    "db status"            { Cmd-DbStatus           }
    "db exec"              { Cmd-DbExec             }
    "db dump"              { Cmd-DbDump             }
    "db dump-test"         { Cmd-DbDumpTest         }
    "db dump-head"         { Cmd-DbDumpHead         }
    "db dump-tail"         { Cmd-DbDumpTail         }
    "db dump-tables"       { Cmd-DbDumpTables       }
    "db dump-grep"         { Cmd-DbDumpGrep         }
    "docker pull-restart"  { Cmd-DockerPullRestart  }
    "config"               { Cmd-Config             }
    default                { Show-Usage             }
}