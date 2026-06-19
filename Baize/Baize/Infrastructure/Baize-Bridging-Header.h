//
//  Baize-Bridging-Header.h
//  Baize
//
//  Swift ↔ Objective-C++ Bridging Header
//  导入 NodeEngineBridge.h 以便 Swift 调用 nodejs-mobile 引擎
//  导入 Python.h 以便 Swift 调用 CPython C API
//  导入 git2.h 以便 Swift 调用 libgit2 C API（Git 集成）
//  导入 zlib.h 以便 Swift 直接调用系统 zlib（绕过 libgit2 内部 zlib 问题）
//  导入 CommonCrypto 以便 Swift 计算 SHA-1（手动创建 git 对象时使用）
//

#import "NodeEngineBridge.h"

#import <Python/Python.h>

#import "git2.h"

// Bug fix (P0, round 7): libgit2 内部 zlib 初始化失败 ("failed to initialize zlib")
// 需要直接调用系统 zlib (libz.tbd) 来手动创建 git loose objects，绕过 libgit2 的 deflate。
#import <zlib.h>

// 手动创建 git 对象时需要计算 SHA-1（git_oid 的底层实现就是 SHA-1）
#import <CommonCrypto/CommonDigest.h>
