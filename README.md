# Introduction

> **DISCLAIMER:**  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

This is an example meta layer used for building SD Image for Raspberry Pi 3B+ device that enabled the following functionalities:

- IoT Hub Device Update Agent
  - SWUpdate and SWUpdate V2 handlers
  - Script handler
  - Delta Downloader (for Delta-update support)
  - Device Update data partition (/adu)
- Delivery Optimization Agent
- Custom swupdate that supports:
  - zstd compression
  - custom hardware compat file (/etc/adu-swupdate-hw-compat)
- Dual-partition (A/B) Update
  - adu-raspberrypi.wks creates 2 file system partitions to support A/B update.

In addition, this layer also produces SWU file that can be used for updating the previous version of the image, using swupdate tool.

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
