> **DISCLAIMER:**  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


# Introduction
The goal of this document is to impart on the reader the necessary changes required to integrate the Device Update for IoT Hub agent with a board that isn't a RaspberryPi 4. These are not the total list of requirements to get your device ready to use an A/B Update System nor should it be considered a full guide on how to make your image Device Update Ready. 

Instead we focus on the things that are completed by this repository with recommendations for further improvements and considerations the reader may make after reading. 

You must work with your BSP provider to determine how to accomplish some of these tasks. 


# Core Items to Prep an Image Build System

To use Device Update for IoT Hub there are some requirements that your image build system must complete in order to work with the agent. 

1. The prepared image MUST contain at least three partitions: the A partition, the B partition, and the ADU partition
2. The prepared image MUST overload or modify the existing bootloader such that the system is able to load into either the A or B partition. The boot logic will be determined by your BSP. You must add the ability to set flags in order to use the correct partition after an update. You can see the one the proof-of-concept agent uses [here](./recipes-bsp/rpi-u-boot-scr/rpi-u-boot-scr.bbappend). Likely you will be able to append the image you're targeting's default bootloader but that will be on a case-by-case basis. 
3. The image build system MUST bake a hardware compatibility file into the image. The Device Update proof-of-concept creates this within the [recipes-support/adu-swupdate-hw-compat.bb](./recipes-support/adu-swupdate-hw-compat/adu-swupdate-hw-compat.bb) but you can choose to use whatever file or versioning method you would like. 
4. If you are using the [meta-azure-device-update repository](https://github.com/Azure/meta-azure-device-update) meta layer to bake the image in you must set the `ADU_SOFTWARE_VERSION` to the version of Device Update you are using within your build system. 

These are general guidances on larger scale items that need to be taken care of for the agent to build properly for your device. The following sections will focus on what the Device Update `meta-raspberrypi-adu` layer is attempting to accomplish in each layer and what considerations you may want to make. If you read the above items and are unsure of how to proceed please reach out to the Device Update team or talk to your BSP provider. Likely an answer to your question will require information from both. 

# On Patches In this Repo

There are a lot of patches within this repository. This is a normal process of developing meta-layers for Yocto. They're intended only for the `meta-raspberrypi` layer. You don't need to think about them, however you might find that you do need to update and or edit your existing BSP with some patches of your own. You can safely disregard them in your port. 

# Recipes

## recipes-bsp 

### What does it do? 

Within our project `recipes-bsp` is used for appending instructions to the bootloader that allow SwUpdate to set which partition to boot into after completing an image update (eg if we've completed an update while running on `/dev/mmcblk0p1` then when the device restarts we boot into `/dev/mmcblk0p2` which contains the new version of the image). For our purposes we can use [rpi-u-boot-scr.bbappend](./recipes-bsp/rpi-u-boot-scr/rpi-u-boot-scr.bbappend) to add the [boot.cmd.in](./recipes-bsp/rpi-u-boot-scr/files/boot.cmd.in) file to the Raspberry Pi 4's boot process which instructs the device to do the A/B switching. 

Within this layer we edit u-boot to use our own firmware environment configuration which sets aside a part of memory for us to store the variable that we use to indicate to the bootloader which partition to boot into. 

There is also a patch for a GCC issue some RaspberryPi's run into. The reader can safely disregard this and any other patch. They are BSP specific and should not be required for your build. 

### What do I need to think about? 

You must talk to your BSP provider and determine what bootloader they provide as apart of the BSP. Likely you will need to create a more durable u-boot script that handles detecting if an update occurred, determines what partition to load into, and provide the logic to do that switching. 

For instance you can look at this snippet: 
```u-boot
fdt addr ${fdt_addr} && fdt get value bootargs /chosen bootargs
fatload mmc 0:1 ${kernel_addr_r} @@KERNEL_IMAGETYPE@@

if test ! -e @@BOOT_MEDIA@@ 0:1 uboot.env; then saveenv; fi;

if env exists rpipart;
then 
  if test "${have_updated}" = 1; then
    if test "${boot_attempts}" = "3";
    then 
      # do a reversion based upon rpipart
      if test "${rpipart}" = "2"; then
        # Revert to three
        setenv rpipart 3
        setenv boot_attempts 0
      else
        if test "${rpipart}" = "3"; then
          # Revert to two
          setenv rpipart 2
          setenv boot_attempts 0
        fi
      fi

    fi
  fi
  
  setenv bootargs "${bootargs} root=/dev/mmcblk0p${rpipart}"; 
fi

setenv boot_attempts boot_attempts + 1
@@KERNEL_BOOTCMD@@ ${kernel_addr_r} - ${fdt_addr}
```

Within the [recipes-core] layer we create three partitions and mount them in the `fstab` : `/dev/mmcblk0p2` (the 'A' partition), `/dev/mmcblk0p3` (the 'B' partition), and `/dev/mmcblk0p4` (the "adu" partition). When an update occurs we write the partition number to boot into next to the u-boot environment section setup using `fw-env.config` which is then used by this u-boot script to determine what partition to load into on the next boot. 

For a production device the core idea of using a flag to say what to load into is completely acceptable, however there are some safety checks you should add if you want your device to be secure and durable. 

First you should also write the hash of the image to be booted into. Then u-boot should hash the partition you're attempting to write into (at least include a CRC checksum) and determine if the partition is what you expect. This prevents direct flash injection attacks and keeps your device from running unsafe code. 

Second you want to add a method for handling a kernel panic. That is if you've completed an update and somehow the partition you're booting into isn't bootable you have a way to fall back from the B side to the A side or vice versa. You can accomplish that using u-boot flags and some logic around what to do when. This is essential to preventing security breaches and making sure your devices have healthy fallbacks. 

Lastly you should look into how your partitions are setup. We only include three partitions + the bootloader in our proof of concept. We use two for updates and one for the Device Update data to be persisted between the two sectors. You may have additional data you need persisted across updates. This would be a place to include some of the boot logic to check whether these sectors are secure or have been messed with since the last boot. Effectively just do secure boot but not secure boot. 

You'll also notice a section in here that's focused on providing a method for rolling back an update. That's why we have the firmware flag `have_updated` and `boot_attempts`. Once there has been an update we set the `have_updated` flag to `1` which indicates to go through the loop, but we only rollback when we've attempted to boot into the devices three times. That causes an auto fallback. 

## recipes-core 

### What does it do? 

The recipes-core meta layer is responsible for finalizing the physical image itself. That is this layer edits the core image being generated and adds all relevant information, operating system setup, and adds the correct file system layout to allow Device Update for IoT Hub to perform it's updates. 

There's only two things this section does to edit the base raspberrypi image to support Device Update. 

First is to add a `fstab` file to the core image that mounts the required partitions by appending the base-files_ within the raspberrypi base image. We accomplish this by overriding the default [fstab file](https://git.yoctoproject.org/poky/tree/meta/recipes-core/base-files/base-files/fstab?h=kirkstone-4.0.17) provided by the Yocto Project and adding our [fstab file](./recipes-core/base-files/base-files/raspberrypi4-64/fstab). 

Second the adu-base-image is defined by [adu-base-image.bb](./recipes-core/images/adu-base-image.bb) and the partitions on the image are created using our [`adu-raspberrypi.wks`](./wic/adu-raspberrypi.wks) script. You can read more about what's going on in that file below and checkout the [wic tool documentation here.](https://docs.yoctoproject.org/dev-manual/wic.html?highlight=wic#creating-partitioned-images-using-wic). A part of building the image is specifying the items that must be installed in this particular image. We use this to define which elements from [meta-azure-device-update](https://github.com/Azure/meta-azure-device-update.git) we're going to be using in this image. This is like a dependency list. It tells Yocto build all of this first and then run the `do_install()` sections of the individual items before you giving me my image. 

### What do I need to think about? 

Whatever system you're doing you need a way to make the A, B, and adu partitions. You can use `wic` like we do or if the tooling from your BSP doesn't support / won't work with `wic` they will provide another method for accomplishing the same task. 

As for making your image you can peruse what we put in our image (look at the `IMAGE_INSTALL` section in the [adu-base-image file](./recipes-core/images/adu-base-image.bb) ), but the most important thing is to include the following assuming you are making no changes to `meta-azure-device-update`: 

1. adu-swupdate-hw-compat
2. adu-device-info-files
3. adu-agent-service

If you have questions about what these are and what they do in the actual image please read the doc in [meta-azure-device-update here]( https://github.com/Azure/meta-azure-device-update). 

## recipes-extended

### What does it do? 

The [recipes-extended](./recipes-extended/) section of the repository is the tooling for generating the SwUpdate file (the `*.swu`) that allows SwUpdate to install the image. Each `*.swu` file must contain a [sw-description file](./recipes-extended/images/adu-update-image/raspberrypi4-64/sw-description) which describes the goal state of the device. You can read more about what a sw-description file is, options you can use, and how to write your own [here](https://sbabic.github.io/swupdate/sw-description.html). 

As apart of the `*.swu` generation swupdate will require that you sign the file with a private key so that the public key that is installed on the device at build time can be used to verify the image. You can read more about how we generate our keys for the proof of concept [here](https://github.com/Azure/iot-hub-device-update-yocto/blob/main/keys/README.md) as well as some recommendations for what to look for in production. 

### What do I need to think about? 

For a customer looking at porting this section over there's not a lot you need to change. You need to edit the file such that it depends on your own custom image's bitbake file, edit the sw-description file to reflect what you would like the system to look like after an update, and provide tooling for accessing a private signing key. 

## recipes-graphics

### What does it do? 
This just sets up graphics for the RPi. 
### What do I need to think about? 
There's nothing that affects customers in this section. You should just be able to entirely omit it from your port. 

## recipes-support
### What does it do? 

In our project the [recipes-support](./recipes-support/) directory appends some of the extra tooling around swupdate. We use the [adu-swupdate-hw-compat.bb](./recipes-support/adu-swupdate-hw-compat/adu-swupdate-hw-compat.bb) to install a hardware compatibility file onto the image which swupdate looks for when completing an update. The version held within this file MUST match the one inside of the `sw-description` file mentioned above. 

We also append swupdate with our own configuration inside of the [defconfig file](./recipes-support/swupdate/swupdate/raspberrypi4-64/defconfig). 
### What do I need to think about? 

For your `hw-compat` file that SwUpdates uses you should have a method for using either a hash of the hardware compatibilities, use a model number for the device you're deploying updates to, or really anything other than just a number that does not allow for any sort of granularity. The version held within this file MUST mach the one inside of the `sw-description` file mentioned above. 


Depending on your use case your `defconfig` may be the same or different. You can read through the options provided by swupdate [here](https://sbabic.github.io/swupdate/swupdate-best-practise.html?highlight=defconfig#swupdate-builtin-configuration). Our configurations reflect the settings for our proof-of-concept. You will likely have different ones. That's ok. The file structure remains the same. Just make sure you edit the `*.swu` bitbake file to provide the items required for your configuration. 


# wic

### What does it do? 
The `wic` directory provides our custom [adu-raspberrypi.wks file](./wic/adu-raspberrypi.wks) which uses the [wic](https://docs.yoctoproject.org/dev-manual/wic.html?highlight=wic#creating-partitioned-images-using-wic) tool within Open Embedded to generate the partitions required for the updates to run. 

### What do I need to think about? 

Your BSP may or may not support `wic`. If they do not you will need to use whatever tool they provide to accomplish the setup of the partitions. The only important consideration for porting is to make sure that you have the four required partitions: bootloader, partition A, partition B, and the ADU partition. 

You will also need to pass the ADU partition's mounting path to the `meta-azure-device-update` build system so the agent knows where to go to look for configuration files. By default we use `/adu/`. 