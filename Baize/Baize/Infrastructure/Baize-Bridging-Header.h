//
//  Baize-Bridging-Header.h
//  Baize
//
//  Swift ↔ Objective-C++ Bridging Header
//  导入 NodeEngineBridge.h 以便 Swift 调用 nodejs-mobile 引擎
//  导入 Python.h 以便 Swift 调用 CPython C API
//  导入 git2.h 以便 Swift 调用 libgit2 C API（Git 集成）
//

#import "NodeEngineBridge.h"

#import <Python/Python.h>

#import <libgit2/git2.h>
