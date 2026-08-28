param(
  [Parameter(Mandatory)] [string]$File,     # e.g. E:\Repository\dfs.records
  [int]$IntervalSec = 5
)

Add-Type -Namespace Win32 -Name Sz -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
'@

function Get-SizeOnDisk([string]$path){
  $high=0
  $low=[Win32.Sz]::GetCompressedFileSizeW($path,[ref]$high)
  if($low -eq 0xFFFFFFFF -and [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0){ return $null }
  return ([int64]$high -shl 32) -bor [int64]$low
}

$drive = (Split-Path -Qualifier $File).TrimEnd(':')
$logical = (Get-Item -LiteralPath $File).Length
$startDisk = Get-SizeOnDisk $File
$startFree = (Get-PSDrive $drive).Free
$t0 = Get-Date

Write-Host ("Monitoring {0}" -f $File) -ForegroundColor Cyan
Write-Host ("Logical size (constant): {0:N2} GB   |   Drive {1}:" -f ($logical/1GB), $drive) -ForegroundColor Cyan
Write-Host ("Start size-on-disk: {0:N2} GB   Start free: {1:N2} GB`n" -f ($startDisk/1GB), ($startFree/1GB))

while ($true) {
  $disk = Get-SizeOnDisk $File
  $free = (Get-PSDrive $drive).Free
  if ($disk -eq $null) { Write-Warning "File not accessible (moved/locked?)"; Start-Sleep $IntervalSec; continue }
  $freedFile = ($startDisk - $disk)/1GB
  $gainedVol = ($free - $startFree)/1GB
  $elapsed = ((Get-Date) - $t0).TotalMinutes
  $rate = if($elapsed -gt 0){ $freedFile/$elapsed } else { 0 }
  Write-Host ("[{0:HH:mm:ss}] on-disk {1,8:N2} GB | freed {2,7:N2} GB | vol free {3,8:N2} GB (+{4,6:N2}) | {5,5:N2} GB/min" -f `
    (Get-Date), ($disk/1GB), $freedFile, ($free/1GB), $gainedVol, $rate)
  Start-Sleep $IntervalSec
}
