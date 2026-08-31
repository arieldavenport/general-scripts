param(
  [Parameter(Mandatory)] [string]$RepoPath,        # repo folder OR a single file
  [switch]$Apply,                                   # omit = measure only; -Apply = reclaim (sets sparse + punches zeros)
  [switch]$Sweep,                                   # benchmark several thread counts (measure-only) and print a table
  [int]$Threads = [Environment]::ProcessorCount,    # threads for a normal run
  [int[]]$SweepThreads = @(2,4,8),                  # thread counts tried in -Sweep mode
  [long]$MinSizeBytes = 1GB                         # ignore files smaller than this when RepoPath is a folder
)

$cs = @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class SparsifyResult {
  public string File;
  public double SizeGB, ReclaimableGB, Seconds, GBps;
  public bool Applied;
}

public static class SparsifyMT {
  const uint FSCTL_SET_SPARSE=0x000900C4, FSCTL_SET_ZERO_DATA=0x000980C8;
  [DllImport("kernel32.dll",SetLastError=true)]
  static extern bool DeviceIoControl(SafeFileHandle h,uint code,byte[] inb,uint ins,IntPtr outb,uint outs,out uint ret,IntPtr ov);

  static long _processed,_reclaimed,_size;
  static volatile bool _done;

  public static SparsifyResult Run(string path, bool apply, int threads, bool showProgress){
    _size=new FileInfo(path).Length; _processed=0; _reclaimed=0; _done=false;
    var res=new SparsifyResult{ File=Path.GetFileName(path), SizeGB=_size/1073741824.0, Applied=apply };
    if(_size==0){ return res; }

    if(apply){
      using(var sh=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.ReadWrite)){
        uint r; if(!DeviceIoControl(sh.SafeFileHandle,FSCTL_SET_SPARSE,null,0,IntPtr.Zero,0,out r,IntPtr.Zero))
          throw new IOException("SET_SPARSE failed err="+Marshal.GetLastWin32Error());
      }
    }

    const long BLK=65536;
    long chunk=(_size+threads-1)/threads;
    chunk=((chunk+BLK-1)/BLK)*BLK;                 // align chunk boundaries to 64KB clusters

    Thread rep=null;
    if(showProgress){ rep=new Thread(()=>Report(path)); rep.IsBackground=true; rep.Start(); }
    var sw=System.Diagnostics.Stopwatch.StartNew();

    Parallel.For(0, threads, new ParallelOptions{MaxDegreeOfParallelism=threads}, t=>{
      long start=(long)t*chunk; if(start>=_size) return;
      long end=Math.Min(start+chunk,_size);
      Worker(path, apply, start, end, BLK);
    });

    _done=true; if(rep!=null) rep.Join(); sw.Stop();
    res.ReclaimableGB=_reclaimed/1073741824.0;
    res.Seconds=sw.Elapsed.TotalSeconds;
    res.GBps=res.SizeGB/Math.Max(res.Seconds,0.001);
    return res;
  }

  static void Worker(string path, bool apply, long start, long end, long BLK){
    int bufSize=4*1024*1024;
    byte[] buf=new byte[bufSize];
    using(var fs=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.ReadWrite,bufSize,FileOptions.SequentialScan)){
      var h=fs.SafeFileHandle;
      fs.Seek(start,SeekOrigin.Begin);
      long pos=start,runStart=-1;
      while(pos<end){
        int want=(int)Math.Min((long)bufSize,end-pos);
        int got=fs.Read(buf,0,want);
        if(got<=0) break;
        int off=0;
        while(off<got){
          int blen=(int)Math.Min(BLK,got-off);
          bool isZero=true;
          for(int i=off;i<off+blen;i++){ if(buf[i]!=0){isZero=false;break;} }
          long abs=pos+off;
          if(isZero){ if(runStart<0) runStart=abs; }
          else { if(runStart>=0){ Punch(h,apply,runStart,abs); runStart=-1; } }
          off+=blen;
        }
        pos+=got;
        Interlocked.Add(ref _processed, got);
      }
      if(runStart>=0) Punch(h,apply,runStart,end);
    }
  }

  static void Punch(SafeFileHandle h, bool apply, long start, long end){
    Interlocked.Add(ref _reclaimed, end-start);
    if(!apply) return;
    byte[] info=new byte[16];
    BitConverter.GetBytes(start).CopyTo(info,0);
    BitConverter.GetBytes(end).CopyTo(info,8);
    uint r;
    if(!DeviceIoControl(h,FSCTL_SET_ZERO_DATA,info,16,IntPtr.Zero,0,out r,IntPtr.Zero))
      throw new IOException("SET_ZERO_DATA failed err="+Marshal.GetLastWin32Error());
  }

  static void Report(string path){
    var sw=System.Diagnostics.Stopwatch.StartNew();
    string name=Path.GetFileName(path);
    while(!_done){
      Thread.Sleep(5000);
      if(_done) break;
      long p=Interlocked.Read(ref _processed), rc=Interlocked.Read(ref _reclaimed);
      double secs=sw.Elapsed.TotalSeconds;
      double gbps= secs>0 ? (p/1073741824.0)/secs : 0;
      double pct= _size>0 ? 100.0*p/_size : 0;
      double eta= gbps>0 ? ((_size-p)/1073741824.0)/gbps/60.0 : 0;
      Console.WriteLine(String.Format("[{0:HH:mm:ss}] {1}  {2:0.0}%  {3:0.0}/{4:0.0} GB  {5:0.00} GB/s  zeros {6:0.0} GB  ETA {7:0.0} min",
        DateTime.Now, name, pct, p/1073741824.0, _size/1073741824.0, gbps, rc/1073741824.0, eta));
    }
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp

# Resolve targets: a single file, or every file in a folder at/above MinSizeBytes
$targets = if (Test-Path -LiteralPath $RepoPath -PathType Leaf) {
  ,(Get-Item -LiteralPath $RepoPath)
} else {
  Get-ChildItem -LiteralPath $RepoPath -File | Where-Object { $_.Length -ge $MinSizeBytes }
}
if(-not $targets){ Write-Warning "No matching files found under $RepoPath"; return }

if ($Sweep) {
  if ($Apply) { Write-Warning "-Sweep is measure-only; ignoring -Apply. No changes will be made." }
  Write-Host "SWEEP (measure-only). Note: OS file cache can inflate later passes on files smaller than RAM." -ForegroundColor Yellow
  foreach($f in $targets){
    Write-Host ("`n=== {0} ({1:0.0} GB) ===" -f $f.Name, ($f.Length/1GB))
    $rows=@()
    foreach($t in $SweepThreads){
      Write-Host ("-- {0} threads --" -f $t)
      $r=[SparsifyMT]::Run($f.FullName, $false, $t, $true)
      $rows += [pscustomobject]@{
        File=$f.Name; Threads=$t
        SizeGB=[math]::Round($r.SizeGB,2)
        ReclaimableGB=[math]::Round($r.ReclaimableGB,2)
        GBps=[math]::Round($r.GBps,2)
        Minutes=[math]::Round($r.Seconds/60,2)
      }
    }
    $rows | Sort-Object GBps -Descending | Format-Table -AutoSize
    $best = $rows | Sort-Object GBps -Descending | Select-Object -First 1
    Write-Host ("Fastest: {0} threads @ {1} GB/s ({2} min). Reclaimable ~{3} GB." -f `
      $best.Threads, $best.GBps, $best.Minutes, $best.ReclaimableGB) -ForegroundColor Green
  }
  Write-Host "`nRe-run with:  -Apply -Threads <best>   (Core stopped) to actually reclaim." -ForegroundColor Cyan
}
else {
  foreach($f in $targets){
    Write-Host ("Processing {0} ({1:0.0} GB) with {2} threads, Apply={3}" -f $f.Name, ($f.Length/1GB), $Threads, [bool]$Apply)
    try {
      $r=[SparsifyMT]::Run($f.FullName, [bool]$Apply, $Threads, $true)
      Write-Host ("DONE {0}: {1:0.00} GB scanned, {2:0.00} GB {3}, {4:0.0} min, {5:0.00} GB/s" -f `
        $r.File, $r.SizeGB, $r.ReclaimableGB, $(if($r.Applied){"FREED"}else{"reclaimable (measure only)"}), ($r.Seconds/60), $r.GBps) -ForegroundColor Green
    }
    catch { Write-Warning ("{0}: {1}" -f $f.Name, $_.Exception.Message) }
  }
}
