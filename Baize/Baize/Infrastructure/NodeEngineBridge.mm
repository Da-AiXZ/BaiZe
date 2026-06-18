//
//  NodeEngineBridge.mm
//  Baize
//
//  ObjC++ 实现 — 将 NSArray argv 转换为 C argv 数组并调用 node_start()
//  关键：node 的 libUV 要求所有 argv 参数字符串存储在连续内存中
//

#import "NodeEngineBridge.h"
#include <NodeMobile/NodeMobile.h>
#include <string.h>
#include <stdlib.h>

@implementation NodeEngineBridge

+ (void)startEngineWithArguments:(NSArray<NSString *> *)arguments {
    // ============================================
    // argv 内存管理：
    // node 的 libUV 要求所有 argv 参数字符串在连续内存中
    // 因此我们用 calloc 分配一块连续内存存储所有参数字符串
    // argv 数组中的每个指针指向这块内存中的对应位置
    // ============================================

    // 1. 计算所有参数字符串所需的总字节数（含 '\0' 终止符）
    int c_arguments_size = 0;
    for (id argElement in arguments) {
        c_arguments_size += strlen([argElement UTF8String]);
        c_arguments_size++;  // '\0' 终止符
    }

    // 2. 在连续内存中分配所有参数字符串的存储空间
    char* args_buffer = (char*)calloc(c_arguments_size, sizeof(char));
    if (args_buffer == NULL) {
        NSLog(@"NodeEngineBridge: Failed to allocate args_buffer");
        return;
    }

    // 3. 分配 argv 指针数组（每个元素指向 args_buffer 中的某个参数字符串）
    int argc = (int)[arguments count];
    char** argv = (char**)malloc(argc * sizeof(char*));
    if (argv == NULL) {
        NSLog(@"NodeEngineBridge: Failed to allocate argv array");
        free(args_buffer);
        return;
    }

    // 4. 填充 args_buffer 和 argv
    //    遍历每个参数，将其复制到 args_buffer 的连续位置
    //    argv[i] 指向该参数在 args_buffer 中的起始位置
    char* current_args_position = args_buffer;
    int argument_count = 0;

    for (id argElement in arguments) {
        const char* current_argument = [argElement UTF8String];
        strncpy(current_args_position, current_argument, strlen(current_argument));
        argv[argument_count] = current_args_position;
        argument_count++;
        current_args_position += strlen(current_args_position) + 1;  // 移动到下一个参数位置（跳过 '\0'）
    }

    // 5. 启动 Node.js（阻塞调用 — 正常情况下不会返回）
    NSLog(@"NodeEngineBridge: starting node_start with %d arguments", argument_count);
    node_start(argument_count, argv);

    // 6. 清理（理论上 node_start 不会返回，但保险起见释放内存）
    NSLog(@"NodeEngineBridge: node_start returned (unexpected — engine should run for app lifetime)");
    free(args_buffer);
    free(argv);
}

@end
