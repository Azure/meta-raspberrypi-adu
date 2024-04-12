> **DISCLAIMER:**  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


# Introduction

This is an example meta layer used for building SD Image for Raspberry Pi 4 device that enabled the following functionalities:

- IoT Hub Device Update Agent with support for
  - SWUpdate V2 updates
  - Script updates (remote execution of all bash scripts)
  - Delta Downloader (for Delta-update support)
- Delivery Optimization Agent
- Custom swupdate that supports:
  - zstd compression
  - custom hardware compat file (/etc/adu-swupdate-hw-compat)
- Dual-partition (A/B) Update
  - adu-raspberrypi.wks creates 2 file system partitions to support A/B update as well as an `/adu/` partition for persisiting agent provisioning information

In addition, this layer also produces a `*.swu` file that can be used for updating the previous version of the image, using swupdate tool. Please keep in mind the produced image is meant for updating TO the version you are building. 

# Recipes

This layer contains the following recipes:

| Recipe Name      | Description |
| ------------- | ---------- |
| recipes-bsp | Customizes `uboot` script to support A/B update strategy. This is required for SWUpdate Handler (for demonstration or reference purposes). |
| recipes-core | Customizes `fstab` to add the 2nd root file system partition (for A/B update strategy) and Device Update data partition (/adu).<br/>This recipe also defines what is included in the base image (adu-base-image).  |
| recipes-extended | This recipe defines what is included in the .swu file (adu-update-image).|
| recipes-graphics | Includes graphics component for the target device. |
| recipes-support | Creates a customized version of swupdate tool that enabled configurations required by SWUpdate Handler and the Delta Downloader. |
| wic | For .wic format support. |
