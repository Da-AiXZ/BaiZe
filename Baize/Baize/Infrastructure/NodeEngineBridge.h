//
//  NodeEngineBridge.h
//  Baize
//
//  Node.js 引擎桥接 — 封装 node_start() C 函数调用
//  必须在 2MB+ 栈空间的后台线程调用
//  @warning node_start() 只能调用一次，不支持重启
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Node.js 引擎桥接对象
/// 将 Swift NSArray 参数转换为 C argv 数组，调用 nodejs-mobile 的 node_start()
@interface NodeEngineBridge : NSObject

/// 启动 Node.js 引擎
/// @param arguments argv 参数数组（第一个元素通常为 "node"）
/// @note 此方法阻塞当前线程，直到 Node.js 引擎退出
/// @warning 整个 App 生命周期只能调用一次
+ (void)startEngineWithArguments:(NSArray<NSString *> *)arguments;

@end

NS_ASSUME_NONNULL_END
