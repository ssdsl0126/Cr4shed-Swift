# Cr4shed Swift - 现代化纯 Swift/Xcode 重构版本
# 不依赖 Theos，使用 XcodeGen + xcodebuild 构建

DEBUG ?= 0
export DEBUG

.PHONY: all generate package clean

all: package

generate:
	xcodegen generate

package: generate
	chmod +x Scripts/package.sh Sources/Packaging/layout/DEBIAN/postinst Sources/Packaging/layout/DEBIAN/postrm
	./Scripts/package.sh

clean:
	rm -rf build .package Cr4shed.xcodeproj packages
