$# Kotlin 排版引擎深度分析报告

## 文档信息
- **分析对象**: `TextChapterLayout.kt` (1363 行), `ReadBook.kt` (1156 行), `ZhLayout.kt` (278 行)
- **分析时间**: 2026-07-30
- **分析目的**: Flutter 排版引擎移植的阅读理解阶段

---

## 1. 核心算法总结

### 1.1 段落分页算法

#### 算法伪代码

```kotlin
// 主排版循环 (TextChapterLayout.kt 第 219-523 行)
suspend fun getTextChapter() {
    // 初始化布局常量和渲染状态
    val textHeight = contentPaintTextHeight
    val fontMetrics = contentPaintFontMetrics
    var durY = 0f // 垂直滚动位置
    
    for (content in contents) {
        currentCoroutineContext().ensureActive()
        
        // 处理特殊标记
        if (content == "[newpage]") {
            prepareNextPageIfNeed()
            continue
        }
        
        // 识别并处理图片
        if (content contains "<img>") {
            parseImageAndInsertPlaceholder(content)
        }
        
        // 调用静态布局进行断行
        val layout = ZhLayout(text, paint, visibleWidth, words, widths, indentSize)
        
        // 逐行排版
        for (lineIndex in 0 until layout.lineCount) {
            // 判断是否需要翻页
            prepareNextPageIfNeed(durY + textHeight)
            
            // 根据行类型应用不同的对齐策略
            when {
                lineIndex == 0 && layout.lineCount > 1 -> 
                    addCharsToLineFirst(...) // 首行缩进两端对齐
                lineIndex == layout.lineCount - 1 ->
                    addCharsToLineNatural(...) // 自然排列（标题居中）
                else ->
                    addCharsToLineMiddle(...) // 中间行两端对齐
            }
            
            // 更新 Y 坐标
            durY += textHeight * lineSpacingExtra
            
            // 添加到当前页面
            textPage.addLine(textLine)
        }
        
        // 段落间距
        durY += textHeight * paragraphSpacing / 10f
    }
}

// 分页控制逻辑 (第 1298-1324 行)
private suspend fun prepareNextPageIfNeed(requestHeight: Float = -1f) {
    if (requestHeight > visibleHeight || requestHeight == -1f) {
        updatePendingPageHeight()
        
        if (doublePage && absStartX < viewWidth / 2) {
            // 双页左列结束
            textPage.leftLineSize = textPage.lineSize
            absStartX = viewWidth / 2 + paddingLeft
        } else {
            // 单页或右列结束，提交页面
            textPage.text = stringBuilder.toString()
            onPageCompleted()
            
            // 重置为新建页面
            pendingTextPage = TextPage()
            absStartX = paddingLeft
            durY = 0f
        }
    }
}
```
