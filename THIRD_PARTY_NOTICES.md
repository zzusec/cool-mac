# 第三方参考与许可

本项目的 AppleSMC ABI、Apple Silicon 风扇模式及 M2 系列传感器映射参考 Stats，固定提交 `c9e7ebe3390a84e3075946ffe39dda709c4747b1`：

- https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/SMC/smc.swift
- https://github.com/exelban/stats/blob/c9e7ebe3390a84e3075946ffe39dda709c4747b1/Modules/Sensors/values.swift

传感器标签采用原始 key，不据系列通用映射猜测本机物理核心编号。没有链接或分发 Stats 的程序、helper 或第三方二进制。SMC 为私有接口；本机实际探测与安全自检是启用控制的前提。

## Stats — MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
