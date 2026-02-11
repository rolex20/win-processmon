# Lower priority to Idle
[System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle
Clear-Host

while ($true) { 
    & "C:\Windows\System32\nvidia-smi.exe" --query-gpu=clocks.sm,clocks.mem,temperature.gpu
    Start-Sleep -Seconds 5
}