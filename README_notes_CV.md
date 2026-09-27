

# Notes and first steps 

with tobiifree see original repo: https://github.com/Aetherall/tobiifree

## calibration file location and format

I supposed that the calibration file is expected in ~/.config/tobii.json
So first i copied the content of the provided calibration file (./calibrations/manual-2026-04-06.json) to ~/.config/tobii.json
but tobiifree-overlay seems to use a different format, e.g. defining the physical screen size in millimeters using w_mm / h_mm ?
I am now using this tobii.json for my laptop screen (sized 30 x 19 cm) but i needed to manually tweak values for cx, cy, z_mm and tilt, 
using some unintuitive values for cy an cx (as the tracker is centered on the lower edge of my laptop screen) - so i might be doing something wrong


```
{
  "display_area": {
    "w_mm": 300,
    "h_mm": 190,
    "cx": -30,
    "cy": -140,
    "z_mm": 50,
    "tilt": 0
  }
}
```

Question is why the exact screen dimension in mm is needed (given that this does not have to be specified in the Tobii Windows driver/SDK)
 - and if we could provide a calibration method that is accessible for people who cannot edit files or deal with complex settings / small UI elements ...

The calibration workbench the fork by georgy-wyy (https://github.com/george-wyy/tobiifree) provides an additional layer for gaze data correction 
(client-side, using affine or poly transformation on top of the on-device calibration) - this is an interesting approach, but still we need to make on-device-calibration made easier / accessible (see below).


## Calibration procedure(s)

I am still unsure how to calibrate the system correctly (e.g. to a new user). 
I noticed the different calibration variants in the web demo, but I am not sure in which way they differ and how to use them correcty
(the goal would be to avoid manual tweaking of the tobii.json config file, and just trigger the calibration procedure for a (new) user, same as with the original Tobii driver.)

* the sliders are helpful for screen size / orientation adjustments - but I do not understand in which way this could generate a tobii.json file with display area settings that are actually useful for local application (so that tobiifreed uses these settings)? 
* do the slider settings actually make a difference for the calibration parameters which are stored to the tobii tracker - or are these just relevant for the web GUI display?
* is it sufficient to run the (5- or 9-point) on-device-calibration to get persistent calibration on the device? It seems that cal_apply is not called after the calibration is finished when used from the web demo .. and there is no button for cal_apply ..
* I made a python calibration script which follows the procedure outlined in the SDK - it connects to tobiifreed, which logs the following messages during the calibration process:

```
info(server): client connected (total: 1)
debug(tracker): cal_start step 0: send 34 bytes
debug(tracker): cal_start step 1: send 44 bytes
info(tracker): cal_start complete in 2 steps
debug(tobiifreed): forwarded cmd=0x21 request_id=7 for fd=11
debug(tobiifreed): routed response for cmd=0x21 to fd=11
debug(tobiifreed): forwarded cmd=0x21 request_id=8 for fd=11
debug(tobiifreed): routed response for cmd=0x21 to fd=11
debug(tobiifreed): forwarded cmd=0x21 request_id=9 for fd=11
debug(tobiifreed): routed response for cmd=0x21 to fd=11
debug(tobiifreed): forwarded cmd=0x21 request_id=10 for fd=11
debug(tobiifreed): routed response for cmd=0x21 to fd=11
debug(tobiifreed): forwarded cmd=0x21 request_id=11 for fd=11
debug(tobiifreed): routed response for cmd=0x21 to fd=11
debug(tracker): cal_finish step 0: send 34 bytes
debug(tracker): cal_finish step 1: send 34 bytes
debug(tracker): cal_finish step 2: send 43 bytes
info(tracker): cal_finish complete in 3 steps
debug(tracker): cal_apply step 0: send 34 bytes
debug(tracker): cal_apply step 1: send 44 bytes
debug(tracker): cal_apply step 2: send 1514 bytes
debug(tracker): cal_apply step 3: send 43 bytes
info(tracker): cal_apply complete in 4 steps
debug(tobiifreed): gaze #500: vL=0 vR=4 x=1.048 y=-0.127
info(server): client disconnected (total: 0)
```

Although this looks correct (cal_apply is sent after cal_finish, including the obtained calibration blob) there is no visible effect of the calibration after it was done (same gaze coordinates, even if i look at wrong locations during calibration ...)
 

## Mouse emulation

I added a mouse emulation client (tobiifree-mouse) which sets the mouse cursor to the current gaze location and provides optional dwell clicking.
It also features client-side calibration and gaze position correction, using a built in calibration GUI and offset correction points which can be added on-demand.


```
usage: gaze_mouse.py [-h] [--socket SOCKET] [--width WIDTH] [--height HEIGHT] [--eye {left,right,both,either}] [--smoothing SMOOTHING]
                     [--retry-delay RETRY_DELAY] [--debug] [--print-eye-origin] [--print-eye-origin-rate PRINT_EYE_ORIGIN_RATE]
                     [--calib-file CALIB_FILE] [--radius RADIUS] [--head-gain HEAD_GAIN]

Map tobiifreed gaze data to the mouse cursor via uinput, with an on-demand calibration GUI and optional eye-origin head-movement
correction.

options:
  -h, --help            show this help message and exit
  --socket SOCKET       Path to tobiifreed's unix socket (default: $XDG_RUNTIME_DIR/tobiifreed/gaze.sock)
  --width WIDTH         Screen width in pixels (default: auto-detect via xrandr)
  --height HEIGHT       Screen height in pixels (default: auto-detect via xrandr)
  --eye {left,right,both,either}
                        Which eye's validity to require (default: either)
  --smoothing SMOOTHING
                        Exponential moving average factor in (0,1]; 0 disables smoothing (default: 0)
  --retry-delay RETRY_DELAY
                        Seconds to wait before reconnecting after a lost connection (default: 2)
  --debug               Print raw/parsed gaze samples and non-gaze messages to stderr
  --print-eye-origin    Continuously print the decoded left/right eye origin (eye_origin_L_mm / eye_origin_R_mm) to stderr, throttled to
                        --print-eye-origin-rate Hz. Useful for verifying the struct extraction is correct.
  --print-eye-origin-rate PRINT_EYE_ORIGIN_RATE
                        Max prints per second for --print-eye-origin (default: 5)
  --calib-file CALIB_FILE
                        Path to calibration points JSON file (default: /home/pi/work/github/tobiifree/applications/python-
                        mouse/calib_points.json)
  --radius RADIUS       Initial calibration correction radius in pixels (default: 300, or whatever is stored in the calib file)
  --head-gain HEAD_GAIN
                        Gain applied to frame-to-frame eye-origin (head) movement when head-movement correction is toggled on via
                        SIGUSR3 (SIGRTMIN); the resulting scaled delta is accumulated into the mouse x/y position each frame. Units
                        depend on tobiifreed's eye-origin coordinate system (often mm) — tune to taste (default: 15.0)
```

The mouse activities can be paused/unpaused using a system-wide hotkey (defined in the Linux Desktop keyboard settings) which sends signals to the running task (SIGUSR1 pause/resume, SIGUSR2 toggle calibration, SIGUSR3 (SIGRTMIN) toggle head-movement correction).
On raspian (using labwc), add the hotkeys to  ~/.config/labwc/rc.xml, e.g.
```
<keyboard>
  <keybind key="A-m">
    <action name="Execute">
      <command>pkill -USR1 -f gaze_mouse.py</command>
    </action>
  </keybind>
  <keybind key="A-c">
    <action name="Execute">
      <command>pkill -USR2 -f gaze_mouse.py</command>
    </action>
  </keybind>
  <keybind key="A-h">
    <action name="Execute">
      <command>pkill -SIGRTMIN -f gaze_mouse.py</command>
    </action>
  </keybind>
</keyboard>
```



## Firmware extraction

I tried to extract the firmware from the .exe files provided with the Tobii driver (i suspected *Tobii.Service.exe* to be the correct file) but no .data section ws found.
I tried different exe files from other installers, and this file worked:

```
Tobii.EyeTracker5.Offline.Installer_4.183.0.30025/Platform/platform_runtime_IS5LEYETRACKER5_service.exe
```

the following CAI containers could be extracted:

```
./extract_firmware /mnt/087EC1427EC128F0/Windows/System32/DriverStore/FileRepository/eyetracker5.inf_amd64_a62d02618eb4f265/platform_runtime_IS5LEYETRACKER5_service.exe fw_extracted/
loaded /mnt/087EC1427EC128F0/Windows/System32/DriverStore/FileRepository/eyetracker5.inf_amd64_a62d02618eb4f265/platform_runtime_IS5LEYETRACKER5_service.exe: 19998560 bytes
.data: raw_off=0x1184a00 raw_size=0x13a600 virt_addr=0x1187000
found 2 CAI container(s)
  [0] off=0x118c8d4 size=1209172 version=t2srv:02a1a6a977 -> fw_extracted//cai_0_t2srv_02a1a6a977.bin
  [1] off=0x12b3c28 size=45665 version=t2srv:02a1a6a977 -> fw_extracted//cai_1_t2srv_02a1a6a977.bin
```

Still, i am unsure if this is correct anecho uinput | sudo tee /etc/modules-load.d/uinput.conf
d the flash tool would work, as i don't want to brick the only ET-5 I have here ;)
does this look correct? - and: how can a ET-5 in runtime mode be put into bootloader mode for accepting new firmware?


## Building / Running on RaspberryPi

### Install Nix and other dependecies on the RaspberryPi, mostly described in the Aetherall's readme:
* get Nix from nixos.org
```
curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh -s -- --daemon
```
* change the following line in flake.nix:
```
    # system = "x86_64-linux";
    system = "aarch64-linux";
```
* run the ./start_nix.sh script. (first time will install dependencies which will take a while)
* install the udev rules for granting USB access:
```
sudo cp assets/99-tobii.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
```
* run ```npm install``` in the repository root folder to install vite for the web demo.


### Mouse emulation

because of the restrictions Wayland imposes to system-wide mouse cursor control, uinput was used, which needs its own udev rule:
```
sudo groupadd uinput
sudo usermod -aG uinput $USER
echo 'KERNEL=="uinput", GROUP="uinput", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

In case of access problems to uinput (for mouse emulation) make sure the module is loaded; if not, add it to modules-load.d using
```
echo uinput | sudo tee /etc/modules-load.d/uinput.conf
```


## Other remarks and findings 


### USB access problems in Chrome
USB access for the Web demo did not work in Chrome (Laptop running Ubuntu, althouth udev rules were correctly installed), unless I enabled the web browser access rights via snap:
(only relevant if the browser was installed via the snap package manager)

```
sudo snap connect chromium:raw-usb
```
 
### tobiifree-overlay screen mapping issue
In my first try I got completely wrong mappings for the gaze point overlay.
I noted following warning messages when running "just overlay":

```
it appears your Wayland compositor does not support the Session Lock protocol
** (tobiifree-overlay:15852): WARNING **: 21:08:00.664: Failed to initialize layer surface, it appears your Wayland compositor doesn't support Layer Shell
```

It seems that the gtk4-layer-shell Wayland extension fails to initialize on my laptop (Ubuntu with Gnome/Mutter).

I added log messages to main.zig and found that the gaze x/y coordinates looked good (normalized to 0..1 for the x/y gaze location when looking around at the screen),
but the mapped screen coordinates where completely wrong, e.g:

```
Info(overlay): gaze norm: x=0.200 y=0.358 | screen px: x=307 y=344 | screen=1536x960 (sample #709)
```

I noticed that the screen size was detected as 1536 x 960 - which is wrong, as I used a resolution of 1920 x 1200 (with a 1.25 scale factor).
The error was bigger than just the scale factor.. It turned out that because the GTK Layer Shell failed, the overlay window silently falls back to a standard floating window with a much smaller size! 

Following a suggestion by Gemini 3.1, I forced the fallback standard window into Fullscreen (and later into an undocked, floating window with fullscreen size because GTK refused to render fullscreen windows with transparent background).
Thus, I got a working gazepoint overlay which matches my actual gaze position quite well!

 
 
