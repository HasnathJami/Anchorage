# Screenshots

The brief asks for screenshots or GIFs of the **running** application. Those have to be
captured on a real device or emulator, so this folder is where they go — it is the one
deliverable that cannot be produced from source.

The reference designs supplied with the brief are in [`../../design/`](../../design/), for
side-by-side comparison.

## What to capture

### Anchorage Perimeter (Android)

| File | State to capture |
| --- | --- |
| `perimeter-01-permission.png` | First launch, the blue "Location permission needed" banner |
| `perimeter-02-no-office.png` | Permission granted, no office anchored — dial reads `--`, pill reads `OFFICE NOT SET` |
| `perimeter-03-out-of-range.png` | Office anchored, standing outside 50 m — red arc, `OUT OF RANGE`, locked padlock **(this is the reference state)** |
| `perimeter-04-in-range.png` | Inside 50 m — green arc, `IN RANGE`, open padlock, button enabled |
| `perimeter-05-marked.png` | After a successful check-in — `CHECKED IN`, "Attendance Marked" |
| `perimeter-06-weak-signal.png` | Indoors with a poor fix — amber `WEAK SIGNAL` |
| `perimeter-07-history.png` | The attendance history screen |
| `perimeter-08-services-off.png` | Device location switched off — amber banner with **Turn on location** |

### Anchorage Harbor (Flutter)

| File | State to capture |
| --- | --- |
| `harbor-01-permission.png` | First launch, "Camera access needed" |
| `harbor-02-camera.png` | Live preview with lens pills, zoom slider and the shutter row **(reference state)** |
| `harbor-03-focus.png` | Mid tap-to-focus, with the yellow reticle visible |
| `harbor-04-batch.png` | Several shots captured — thumbnail badge showing the count |
| `harbor-05-uploading.png` | Upload Manager mid-transfer — active row lifted, throughput visible **(reference state)** |
| `harbor-06-waiting.png` | Aeroplane mode on — rows in amber `WAITING FOR CONNECTION`, chip reads `NO LINK` |
| `harbor-07-retrying.png` | Mock set to `SERVER 503` — red `RETRYING... (ATTEMPT n/5)` |
| `harbor-08-synced.png` | Queue drained — green `SYNCED` rows, 100 % |
| `harbor-09-empty.png` | Empty queue — "Everything is ashore" |

### Recommended GIF

The single most convincing capture is Harbor recovering by itself:

1. Queue a batch with aeroplane mode **on** → rows go amber, `NO LINK`.
2. Turn aeroplane mode **off**.
3. Wait ~3 seconds for the settle window → the chip flips to `STABLE LINK` and the queue
   drains **with no interaction**.

Save it as `harbor-auto-resume.gif`. That is the brief's headline requirement, demonstrated.

## Capturing

```bash
# Android or Flutter, from a connected device
adb exec-out screencap -p > perimeter-03-out-of-range.png

# Screen recording (stop with Ctrl-C, then pull)
adb shell screenrecord --time-limit 30 /sdcard/harbor.mp4
adb pull /sdcard/harbor.mp4

# MP4 → GIF
ffmpeg -i harbor.mp4 -vf "fps=12,scale=420:-1:flags=lanczos" -loop 0 harbor-auto-resume.gif
```

Then reference them from the root `README.md`.
