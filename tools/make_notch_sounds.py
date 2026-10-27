import math, struct, wave, sys, os
SR = 48000
out = sys.argv[1]

def pluck(freq, dur=0.45, amp=1.0, glide=2.0, glide_t=0.025, decay=13.0, attack=0.003, h2=0.12, h3=0.0):
    """Soft modern sine pluck: starts `glide` semitones off and slides onto the note."""
    n = int(SR*dur); s = [0.0]*n; phase = 0.0
    for i in range(n):
        t = i/SR
        g = glide*math.exp(-t/glide_t)
        f = freq*2**(g/12)
        phase += 2*math.pi*f/SR
        env = min(1.0, t/attack)*math.exp(-decay*t)
        s[i] = amp*env*(math.sin(phase) + h2*math.sin(2*phase)*math.exp(-20*t) + h3*math.sin(3*phase)*math.exp(-30*t))
    return s

def mix(track, sound, start, gain=1.0):
    i0 = int(start*SR); need = i0+len(sound)
    if len(track) < need: track.extend([0.0]*(need-len(track)))
    for i,v in enumerate(sound): track[i0+i] += v*gain

def reverb(track, wet=0.18):
    tail = int(0.5*SR); x = track + [0.0]*tail; y = list(x)
    for d,fb in ((0.0297,0.55),(0.0371,0.5),(0.0411,0.45),(0.0437,0.42)):
        D = int(d*SR); buf = [0.0]*len(x)
        for i in range(len(x)):
            buf[i] = x[i] + (buf[i-D]*fb if i>=D else 0)
        for i in range(len(x)): y[i] += wet*0.25*buf[i]
    return y

def write(name, track, peak):
    while track and abs(track[-1]) < 1e-4: track.pop()
    m = max(abs(v) for v in track) or 1
    fade = int(0.015*SR)
    for i in range(min(fade,len(track))): track[-1-i] *= i/fade
    with wave.open(os.path.join(out,name),'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(v/m*peak*32767)) for v in track))

# 완료음 A: two soft rising plucks, a fifth apart (C6 -> G6), slides down onto each note
t=[]; mix(t, pluck(1046.5, glide=-1.5), 0.0, 0.8); mix(t, pluck(1568.0, glide=-1.5, decay=10), 0.085)
write('done_A.wav', reverb(t), 0.5)
# 완료음 B: quick three-step sparkle (G5 B5 D6 -> high G6 shimmer), very short
t=[]
for k,f in enumerate((783.99, 987.77, 1174.66)): mix(t, pluck(f, dur=0.3, glide=1.0, decay=18, h2=0.05), k*0.055, 0.7)
mix(t, pluck(1567.98, dur=0.6, glide=0, decay=7, h2=0.0), 0.165, 0.45)
write('done_B.wav', reverb(t, 0.22), 0.5)

# 대기음 A: "bubble" pair rising (E5 -> B5), each sliding up onto the note, then a softer echo
t=[]
for start,g in ((0.0,1.0),(0.32,0.45)):
    mix(t, pluck(659.25, dur=0.4, glide=-3, glide_t=0.04, decay=9, h2=0.18), start, g)
    mix(t, pluck(987.77, dur=0.5, glide=-3, glide_t=0.04, decay=7, h2=0.18), start+0.11, g)
write('attention_A.wav', reverb(t), 0.62)
# 대기음 B: three quick taps on one note, then a higher note (A5 A5 A5 E6) — "look here"
t=[]
for k in range(3): mix(t, pluck(880.0, dur=0.18, glide=0.5, decay=26, h2=0.2), k*0.09, 0.75)
mix(t, pluck(1318.5, dur=0.6, glide=-2, glide_t=0.03, decay=6.5, h2=0.15), 0.3, 0.9)
write('attention_B.wav', reverb(t), 0.62)
