#!/usr/bin/env bash
# Makes the throwaway test files for M1/M3/M4 into ./testkit/ (git-ignored). Needs ffmpeg and ImageMagick (convert).
# NOT yet run on the owner's computer: check the output sizes before pushing them to the phone.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p testkit && cd testkit

need() { command -v "$1" >/dev/null || { echo "Missing tool: $1"; exit 1; }; }
need ffmpeg; need convert

photo() { # name width height
  convert -size "${2}x${3}" plasma: -quality 92 "$1"
}
for i in $(seq -w 1 20); do photo "small_$i.jpg" 4000 3000; done
photo big_photo_12MB.jpg 9000 6000        # over the 10 MB bot photo limit; check its size
photo pano_12000x1000.jpg 12000 1000      # outside sendPhoto's shape limits
convert -size 1080x2400 plasma: screen_01.png
cp small_01.jpg "ünïcödé name & spaces (1).jpg"
cp small_02.jpg "$(printf 'long_%.0s' $(seq 1 40)).jpg"
cp small_03.jpg IMG-20261101-WA0001.jpg   # date comes from the name (strip EXIF yourself with exiftool -all= if installed)

clip() { # name seconds bitrate
  ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=440" \
    -t "$2" -c:v libx264 -b:v "$3" -c:a aac -shortest "$1"
}
clip clip_30MB.mp4 120 2M
clip clip_49_9MB.mp4 200 2M               # tune the seconds until the file is just under 52,428,800 bytes
clip clip_50MB.mp4 210 2M                 # tune until exactly over 52,428,800 bytes
clip clip_75MB.mp4 300 2M
clip clip_1GB.mp4 4200 2M                 # about 1 GB; long
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1080x1920:rate=30" -t 20 -metadata:s:v rotate=90 -c:v libx264 rotated_portrait.mp4

ls -l
echo "Check the sizes of clip_49_9MB.mp4 (must be < 52428800) and clip_50MB.mp4 (must be >= 52428800); adjust the seconds if not."
