TARGET := iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DictaKey
DictaKey_FILES = Tweak.xm
DictaKey_FRAMEWORKS = UIKit CoreGraphics AudioToolbox
DictaKey_CFLAGS = -I../vosk-armv7/include
DictaKey_LDFLAGS = -Wl,-force_load,../vosk-armv7/libvosk.a -framework Accelerate -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk
