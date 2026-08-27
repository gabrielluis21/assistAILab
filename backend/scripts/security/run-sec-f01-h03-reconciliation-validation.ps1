param(
  [Parameter(Mandatory = $true)]
  [string]$DatabaseUrl
)

$ErrorActionPreference = "Stop"

$ExpectedDb = "assistailab_sec_f01_h03"
$OldMigration = "20260826_sec_f01_idempotency_v2"
$NewMigration = "20260826163000_sec_f01_idempotency_v2"
$CleanupMigration = "20260826163526_"
$H02Migration = "20260826164000_sec_f01_h02_lease_ownership"

try {
  $uri = [System.Uri]$DatabaseUrl
  $dbName = $uri.AbsolutePath.Trim("/")
}
catch {
  throw "Invalid DATABASE_URL."
}

if ($dbName -ne $ExpectedDb) {
  throw "SAFETY STOP: only '$ExpectedDb' is allowed. Got '$dbName'."
}

$backend = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$repo = (Resolve-Path (Join-Path $backend "..")).Path

if (-not (Test-Path (Join-Path $backend "package.json"))) {
  throw "Backend root could not be resolved from script location."
}

$mainPrisma = Join-Path $backend "prisma"
$workspace = Join-Path $repo ".h03-reconciliation-validation"
$workspacePrisma = Join-Path $workspace "prisma"
$workspaceMigrations = Join-Path $workspacePrisma "migrations"
$queryRunner = Join-Path $backend ".h03-reconciliation-query.mjs"

$report = Join-Path $repo (
  "H03_RECONCILIATION_REPORT_" +
  (Get-Date -Format "yyyyMMdd_HHmmss") +
  ".txt"
)

$npxCmd = (Get-Command npx.cmd -ErrorAction Stop).Source
$nodeCmd = (Get-Command node.exe -ErrorAction Stop).Source

$env:DATABASE_URL = $DatabaseUrl

if (Test-Path $workspace) {
  Remove-Item -Recurse -Force $workspace
}

New-Item -ItemType Directory -Force $workspaceMigrations | Out-Null

Copy-Item `
  (Join-Path $mainPrisma "schema.prisma") `
  (Join-Path $workspacePrisma "schema.prisma")

Copy-Item `
  (Join-Path $mainPrisma "migrations\migration_lock.toml") `
  (Join-Path $workspaceMigrations "migration_lock.toml")

$historicalMigrations = @(
  "20260814163613_init",
  "20260817195711_crm_and_media_foundation",
  "20260819161250_crm_profile_per_organization",
  "20260820134344_equipment_ownership_and_acquisition"
)

foreach ($name in $historicalMigrations) {
  Copy-Item `
    -Recurse `
    (Join-Path $mainPrisma "migrations\$name") `
    (Join-Path $workspaceMigrations $name)
}

$oldDir = Join-Path $workspaceMigrations $OldMigration
New-Item -ItemType Directory -Force $oldDir | Out-Null

Copy-Item `
  (Join-Path $mainPrisma "migrations\$NewMigration\migration.sql") `
  (Join-Path $oldDir "migration.sql")

$schemaPath = Join-Path $workspacePrisma "schema.prisma"

$queryRunnerSource = @(
  "import { PrismaClient } from '@prisma/client';",
  "",
  "const prisma = new PrismaClient();",
  "",
  "try {",
  "  const sql = Buffer.from(process.env.H03_SQL_B64 ?? '', 'base64').toString('utf8');",
  "  const rows = await prisma.`$queryRawUnsafe(sql);",
  "  console.log(JSON.stringify(rows, (_, value) => typeof value === 'bigint' ? value.toString() : value, 2));",
  "} finally {",
  "  await prisma.`$disconnect();",
  "}"
) -join "`n"

Set-Content -Path $queryRunner -Value $queryRunnerSource -Encoding UTF8

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($report, $false, $utf8NoBom)
$writer.AutoFlush = $true

function Write-Log {
  param([string]$Text)

  $writer.WriteLine($Text)
  Write-Host $Text
}

function Invoke-Captured {
  param(
    [string]$Exe,
    [string]$WorkingDirectory,
    [string[]]$Arguments
  )

  Push-Location $WorkingDirectory

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $output = & $Exe @Arguments 2>&1
    $exitCode = [int]$LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
  }

  return [pscustomobject]@{
    Output = @($output)
    ExitCode = $exitCode
  }
}

function Invoke-NpxLogged {
  param(
    [string]$Label,
    [string[]]$Arguments
  )

  Write-Log ""
  Write-Log "===== $Label ====="
  Write-Log ("COMMAND: npx " + ($Arguments -join " "))

  $result = Invoke-Captured `
    -Exe $npxCmd `
    -WorkingDirectory $backend `
    -Arguments $Arguments

  foreach ($line in $result.Output) {
    Write-Log ($line.ToString())
  }

  Write-Log "EXIT_CODE: $($result.ExitCode)"
  return $result
}

function Invoke-SqlExecute {
  param(
    [string]$Label,
    [string]$Sql
  )

  Write-Log ""
  Write-Log "===== $Label ====="

  Push-Location $backend

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"

  try {
    $output = $Sql |
      & $npxCmd prisma db execute --url $DatabaseUrl --stdin 2>&1
    $exitCode = [int]$LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
  }

  foreach ($line in @($output)) {
    Write-Log ($line.ToString())
  }

  Write-Log "EXIT_CODE: $exitCode"

  if ($exitCode -ne 0) {
    throw "$Label failed."
  }
}

function Invoke-SqlQuery {
  param(
    [string]$Label,
    [string]$Sql
  )

  Write-Log ""
  Write-Log "===== $Label ====="

  $env:H03_SQL_B64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes($Sql)
  )

  try {
    $result = Invoke-Captured `
      -Exe $nodeCmd `
      -WorkingDirectory $backend `
      -Arguments @(".h03-reconciliation-query.mjs")
  }
  finally {
    Remove-Item Env:H03_SQL_B64 -ErrorAction SilentlyContinue
  }

  foreach ($line in $result.Output) {
    Write-Log ($line.ToString())
  }

  Write-Log "EXIT_CODE: $($result.ExitCode)"

  if ($result.ExitCode -ne 0) {
    throw "$Label failed."
  }

  $jsonText = (
    $result.Output |
    ForEach-Object { $_.ToString() }
  ) -join "`n"

  return $jsonText | ConvertFrom-Json
}

try {
  Write-Log "SEC-F01-H03 CONTROLLED MIGRATION IDENTITY RECONCILIATION"
  Write-Log ("Started: " + (Get-Date -Format o))
  Write-Log "Database: $ExpectedDb"
  Write-Log "DISPOSABLE DATABASE ONLY."
  Write-Log "No migrate resolve. No migrate reset. No real-DB history edits."

  $prepare = Invoke-NpxLogged `
    -Label "PREPARE CLEAN OLD-NAME BEFORE STATE" `
    -Arguments @(
      "prisma",
      "migrate",
      "deploy",
      "--schema",
      $schemaPath
    )

  if ($prepare.ExitCode -ne 0) {
    throw "Could not prepare clean historical state."
  }

  $sentinelInsertSql = @(
    "INSERT INTO operation_idempotency (",
    "  operationId,",
    "  endpoint,",
    "  requestHash,",
    "  responseStatus,",
    "  responseBody,",
    "  organizationId,",
    "  command,",
    "  status,",
    "  completedAt",
    ") VALUES (",
    "  'H03-RECONCILIATION-SENTINEL',",
    "  '/h03/reconciliation',",
    "  'approved-sentinel',",
    "  200,",
    "  JSON_OBJECT('preserve', true),",
    "  NULL,",
    "  'H03_RECONCILIATION',",
    "  'COMPLETED',",
    "  CURRENT_TIMESTAMP(3)",
    ");"
  ) -join "`n"

  Invoke-SqlExecute `
    -Label "INSERT SENTINEL" `
    -Sql $sentinelInsertSql

  Remove-Item -Recurse -Force $workspaceMigrations
  Copy-Item -Recurse (Join-Path $mainPrisma "migrations") $workspaceMigrations

  $historySql = @(
    "SELECT",
    "  id,",
    "  migration_name,",
    "  checksum,",
    "  started_at,",
    "  finished_at,",
    "  rolled_back_at,",
    "  applied_steps_count",
    "FROM _prisma_migrations",
    "WHERE migration_name IN (",
    "  '$OldMigration',",
    "  '$NewMigration',",
    "  '$CleanupMigration',",
    "  '$H02Migration'",
    ")",
    "ORDER BY started_at;"
  ) -join "`n"

  $historyBefore = Invoke-SqlQuery `
    -Label "MIGRATION HISTORY BEFORE REPAIR" `
    -Sql $historySql

  if (
    @($historyBefore).Count -ne 1 -or
    $historyBefore.migration_name -ne $OldMigration -or
    $null -eq $historyBefore.finished_at -or
    $null -ne $historyBefore.rolled_back_at
  ) {
    throw "BEFORE history is not the exact clean OLD state."
  }

  $sentinelQuerySql = @(
    "SELECT",
    "  operationId,",
    "  endpoint,",
    "  status,",
    "  JSON_EXTRACT(responseBody, '$.preserve') AS preserveValue",
    "FROM operation_idempotency",
    "WHERE operationId = 'H03-RECONCILIATION-SENTINEL';"
  ) -join "`n"

  $sentinelBefore = Invoke-SqlQuery `
    -Label "SENTINEL BEFORE REPAIR" `
    -Sql $sentinelQuerySql

  if (
    @($sentinelBefore).Count -ne 1 -or
    $sentinelBefore.status -ne "COMPLETED"
  ) {
    throw "Sentinel BEFORE is missing or invalid."
  }

  $negativeTests = Invoke-NpxLogged `
    -Label "NEGATIVE / IDEMPOTENCY UNIT TESTS" `
    -Arguments @(
      "tsx",
      "--test",
      "src/core/idempotency/sec_f01_h03_reconciliation.test.ts"
    )

  if ($negativeTests.ExitCode -ne 0) {
    throw "H03 negative tests failed."
  }

  $check = Invoke-NpxLogged `
    -Label "REPAIR CHECK" `
    -Arguments @(
      "tsx",
      "src/tools/security/sec_f01_h03_reconcile.ts",
      "check"
    )

  $checkText = $check.Output -join "`n"

  if (
    $check.ExitCode -ne 0 -or
    $checkText -notmatch '"state":\s*"READY"'
  ) {
    throw "H03 check did not report READY."
  }

  $apply = Invoke-NpxLogged `
    -Label "REPAIR APPLY" `
    -Arguments @(
      "tsx",
      "src/tools/security/sec_f01_h03_reconcile.ts",
      "apply"
    )

  $applyText = $apply.Output -join "`n"

  if (
    $apply.ExitCode -ne 0 -or
    $applyText -notmatch '"result":\s*"APPLIED"'
  ) {
    throw "H03 apply did not report APPLIED."
  }

  $repeat = Invoke-NpxLogged `
    -Label "REPAIR APPLY REPEATED - IDEMPOTENCY" `
    -Arguments @(
      "tsx",
      "src/tools/security/sec_f01_h03_reconcile.ts",
      "apply"
    )

  $repeatText = $repeat.Output -join "`n"

  if (
    $repeat.ExitCode -ne 0 -or
    $repeatText -notmatch '"result":\s*"ALREADY_RECONCILED"'
  ) {
    throw "Repeated H03 apply was not an idempotent no-op."
  }

  $historyAfterRepair = Invoke-SqlQuery `
    -Label "MIGRATION HISTORY AFTER REPAIR BEFORE DEPLOY" `
    -Sql $historySql

  if (
    @($historyAfterRepair).Count -ne 1 -or
    $historyAfterRepair.migration_name -ne $NewMigration -or
    $historyAfterRepair.id -ne $historyBefore.id -or
    $historyAfterRepair.checksum -ne $historyBefore.checksum -or
    $historyAfterRepair.started_at -ne $historyBefore.started_at -or
    $historyAfterRepair.finished_at -ne $historyBefore.finished_at -or
    $historyAfterRepair.rolled_back_at -ne $historyBefore.rolled_back_at -or
    ([string]$historyAfterRepair.applied_steps_count) -ne
      ([string]$historyBefore.applied_steps_count)
  ) {
    throw "Repair changed more than migration_name or produced unexpected history."
  }

  $sentinelAfterRepair = Invoke-SqlQuery `
    -Label "SENTINEL AFTER REPAIR BEFORE DEPLOY" `
    -Sql $sentinelQuerySql

  if (
    @($sentinelAfterRepair).Count -ne 1 -or
    $sentinelAfterRepair.status -ne "COMPLETED"
  ) {
    throw "Sentinel changed during reconciliation."
  }

  $statusBeforeDeploy = Invoke-NpxLogged `
    -Label "PRISMA MIGRATE STATUS AFTER REPAIR" `
    -Arguments @(
      "prisma",
      "migrate",
      "status",
      "--schema",
      $schemaPath
    )

  $statusText = $statusBeforeDeploy.Output -join "`n"

  if ($statusText -match [regex]::Escape($OldMigration)) {
    throw "OLD migration still appears in migrate status after repair."
  }

  if ($statusText -match "not found locally") {
    throw "Migration histories still diverge after repair."
  }

  $deploy = Invoke-NpxLogged `
    -Label "PRISMA MIGRATE DEPLOY AFTER REPAIR" `
    -Arguments @(
      "prisma",
      "migrate",
      "deploy",
      "--schema",
      $schemaPath
    )

  if ($deploy.ExitCode -ne 0) {
    throw "Post-repair migrate deploy failed."
  }

  $deployText = $deploy.Output -join "`n"

  if (
    $deployText -match (
      "Applying migration.*" +
      [regex]::Escape($NewMigration)
    )
  ) {
    throw "SEC-F01 base was reapplied after reconciliation."
  }

  if (
    $deployText -notmatch [regex]::Escape($CleanupMigration)
  ) {
    throw "Cleanup migration was not applied."
  }

  if (
    $deployText -notmatch [regex]::Escape($H02Migration)
  ) {
    throw "H02 migration was not applied."
  }

  $historyAfterDeploy = Invoke-SqlQuery `
    -Label "MIGRATION HISTORY AFTER DEPLOY" `
    -Sql $historySql

  $oldCount = @(
    $historyAfterDeploy |
    Where-Object {
      $_.migration_name -eq $OldMigration
    }
  ).Count

  $newCount = @(
    $historyAfterDeploy |
    Where-Object {
      $_.migration_name -eq $NewMigration -and
      $null -ne $_.finished_at -and
      $null -eq $_.rolled_back_at
    }
  ).Count

  $cleanupCount = @(
    $historyAfterDeploy |
    Where-Object {
      $_.migration_name -eq $CleanupMigration -and
      $null -ne $_.finished_at -and
      $null -eq $_.rolled_back_at
    }
  ).Count

  $h02Count = @(
    $historyAfterDeploy |
    Where-Object {
      $_.migration_name -eq $H02Migration -and
      $null -ne $_.finished_at -and
      $null -eq $_.rolled_back_at
    }
  ).Count

  if (
    $oldCount -ne 0 -or
    $newCount -ne 1 -or
    $cleanupCount -ne 1 -or
    $h02Count -ne 1
  ) {
    throw (
      "Final migration counts failed acceptance: " +
      "old=$oldCount new=$newCount " +
      "cleanup=$cleanupCount h02=$h02Count"
    )
  }

  $sentinelAfterDeploy = Invoke-SqlQuery `
    -Label "SENTINEL AFTER DEPLOY" `
    -Sql $sentinelQuerySql

  if (
    @($sentinelAfterDeploy).Count -ne 1 -or
    $sentinelAfterDeploy.status -ne "COMPLETED"
  ) {
    throw "Sentinel is not intact after deploy."
  }

  $schemaAfterSql = @(
    "SELECT",
    "  COLUMN_NAME AS columnName,",
    "  IS_NULLABLE AS isNullable,",
    "  COLUMN_DEFAULT AS columnDefault",
    "FROM information_schema.COLUMNS",
    "WHERE TABLE_SCHEMA = DATABASE()",
    "  AND TABLE_NAME = 'operation_idempotency'",
    "  AND COLUMN_NAME IN ('updatedAt', 'leaseToken')",
    "ORDER BY COLUMN_NAME;"
  ) -join "`n"

  $schemaAfter = Invoke-SqlQuery `
    -Label "FINAL H02 / CLEANUP SCHEMA" `
    -Sql $schemaAfterSql

  $updatedAt = $schemaAfter |
    Where-Object { $_.columnName -eq "updatedAt" }

  $leaseToken = $schemaAfter |
    Where-Object { $_.columnName -eq "leaseToken" }

  if (
    $null -eq $updatedAt -or
    $null -ne $updatedAt.columnDefault
  ) {
    throw "Cleanup schema assertion failed: updatedAt default was not removed."
  }

  if (
    $null -eq $leaseToken -or
    $leaseToken.isNullable -ne "YES"
  ) {
    throw "H02 schema assertion failed: nullable leaseToken is missing."
  }

  $finalStatus = Invoke-NpxLogged `
    -Label "FINAL PRISMA MIGRATE STATUS" `
    -Arguments @(
      "prisma",
      "migrate",
      "status",
      "--schema",
      $schemaPath
    )

  $finalStatusText = $finalStatus.Output -join "`n"

  if (
    $finalStatus.ExitCode -ne 0 -or
    $finalStatusText -notmatch "Database schema is up to date"
  ) {
    throw "Final migrate status is not up to date."
  }

  $finalRepeat = Invoke-NpxLogged `
    -Label "FINAL REPAIR REEXECUTION - IDEMPOTENT NO-OP" `
    -Arguments @(
      "tsx",
      "src/tools/security/sec_f01_h03_reconcile.ts",
      "apply"
    )

  $finalRepeatText = $finalRepeat.Output -join "`n"

  if (
    $finalRepeat.ExitCode -ne 0 -or
    $finalRepeatText -notmatch '"result":\s*"ALREADY_RECONCILED"'
  ) {
    throw "Final repair reexecution is not idempotent."
  }

  Write-Log ""
  Write-Log "===== RESULT ====="
  Write-Log "SEC-F01-H03 DISPOSABLE RECONCILIATION VALIDATION: PASS"
  Write-Log "OLD migration identity reconciled to NEW exactly once."
  Write-Log "No SEC-F01 base reapplication occurred."
  Write-Log "Cleanup migration applied exactly once."
  Write-Log "H02 migration applied exactly once."
  Write-Log "Sentinel data remained intact."
  Write-Log "Final schema matches cleanup + H02."
  Write-Log "Final migrate status is up to date."
  Write-Log "Repeated repair execution is an idempotent no-op."
  Write-Log ("Finished: " + (Get-Date -Format o))
}
finally {
  Remove-Item Env:H03_SQL_B64 -ErrorAction SilentlyContinue

  if ($writer) {
    $writer.Flush()
    $writer.Dispose()
  }

  if (Test-Path $queryRunner) {
    Remove-Item -Force $queryRunner
  }

  if (Test-Path $workspace) {
    Remove-Item -Recurse -Force $workspace
  }
}

Write-Host ""
Write-Host "Report: $report"
