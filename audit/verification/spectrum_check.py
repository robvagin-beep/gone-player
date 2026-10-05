"""Port of AudioEngineNext.processSpectrum bar mapping + level normalisation."""
import numpy as np
N=1024; BARS=28
win = np.hanning(N+1)[:N].astype(np.float32)  # vDSP_hann_window HANN_NORM ~ periodic hann
def bars_for(sr):
    bw = sr/N; lmin=np.log10(55); lmax=np.log10(18000); out=[]
    for b in range(BARS):
        lo=10**(lmin+(lmax-lmin)*b/BARS); hi=10**(lmin+(lmax-lmin)*(b+1)/BARS)
        li=max(0,int(lo/bw)); ui=min(N//2-1,int(hi/bw)); out.append((li,ui))
    return out
def spectrum(x, sr):
    xw=x[:N]*win
    # vDSP_fft_zrip packed output scaled by 2 relative to the math DFT; zvmags = re^2+im^2
    X=np.fft.rfft(xw)*2
    mags=np.abs(X[:N//2])**2
    mags[0]=(X[0].real**2)+(X[N//2].real**2)   # packed DC+Nyquist in bin 0
    res=[]
    for i,(li,ui) in enumerate(bars_for(sr)):
        pk=mags[li:ui+1].max() if li<=ui else 0
        db=10*np.log10(max(1e-10,pk))
        if i<8: n=(db-20)/30
        elif i<19: n=(db+10)/50
        else: n=(db+10)/40
        res.append(min(1,max(0,n))*0.24)
    return res
for sr in [44100,48000,96000,192000]:
    b=bars_for(sr)
    dc_bars=[i for i,(li,ui) in enumerate(b) if li==0]
    dup=sum(1 for i in range(1,BARS) if b[i]==b[i-1])
    print(f"{sr:6d} Hz: bin width {sr/N:6.1f} Hz, bars reading DC/Nyquist bin 0: {dc_bars}, bars identical to previous: {dup}")
    for f in [60,1000,10000]:
        t=np.arange(N)/sr; x=(0.5*np.sin(2*np.pi*f*t)).astype(np.float32)
        s=spectrum(x,sr); pk=int(np.argmax(s))
        lo=55*(18000/55)**(pk/BARS); hi=55*(18000/55)**((pk+1)/BARS)
        print(f"   sine {f:5d} Hz → loudest bar {pk:2d} ({lo:7.0f}-{hi:7.0f} Hz) level {max(s):.3f}")
    # DC offset only (silence with 0.01 DC) — should be all zeros
    s=spectrum(np.full(N,0.01,np.float32),sr)
    print("   DC 0.01 only → bar0 level", round(s[0],3))
