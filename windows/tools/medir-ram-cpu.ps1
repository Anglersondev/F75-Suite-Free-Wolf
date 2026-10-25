# Mede RAM e CPU em repouso do driver original e do F75 Studio.
# Uso: abra SO UM dos programas, deixe parado, e rode:
#   powershell -ExecutionPolicy Bypass -File .\medir-ram-cpu.ps1 -Segundos 60
param([int]$Segundos = 60)
$origDir = 'C:\Program Files\FREE  WOLF  F75'
$procs = Get-Process | Where-Object {
  $_.ProcessName -eq 'F75 Studio' -or ($_.Path -and $_.Path.StartsWith($origDir, 'OrdinalIgnoreCase'))
}
if (-not $procs) { Write-Host 'Nenhum processo do F75 (original ou F75 Studio) aberto.'; exit 1 }
$t0 = @{}; foreach ($p in $procs) { $t0[$p.Id] = $p.TotalProcessorTime }
Write-Host "Medindo $Segundos s sem mexer no PC..."
Start-Sleep -Seconds $Segundos
$cores = [Environment]::ProcessorCount
$linhas = foreach ($p in $procs) {
  $p.Refresh()
  $cpuMs = ($p.TotalProcessorTime - $t0[$p.Id]).TotalMilliseconds
  $priv = (Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter "IDProcess=$($p.Id)").WorkingSetPrivate
  [pscustomobject]@{
    Processo          = $p.ProcessName
    'CPU ms'          = [math]::Round($cpuMs, 1)
    'CPU % (total)'   = [math]::Round($cpuMs / ($Segundos * 10 * $cores), 3)
    'RAM Gerenc. MiB' = [math]::Round($priv / 1MB, 1)   # coluna "Memoria" do Gerenciador
    'Working set MiB' = [math]::Round($p.WorkingSet64 / 1MB, 1)
    'Privada MiB'     = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
    Threads           = $p.Threads.Count
    Handles           = $p.HandleCount
  }
}
$linhas | Format-Table -AutoSize
