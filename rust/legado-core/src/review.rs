//! 段评/本章热评

use serde::{Deserialize, Serialize};

/// 章节评论（段评或本章热评）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterReview {
    pub id: i64,
    pub book_url: String,
    pub chapter_index: i32,
    pub paragraph_index: i32, // 段落索引（-1 表示本章热评）
    pub content: String,
    pub author: String,
    pub created_at: i64, // Unix 时间戳（毫秒）
    pub like_count: i32,
}

impl ChapterReview {
    /// 判断是否为本章热评（paragraph_index == -1）
    pub fn is_chapter_hot_review(&self) -> bool {
        self.paragraph_index < 0
    }

    /// 判断是否为段评
    pub fn is_paragraph_review(&self) -> bool {
        self.paragraph_index >= 0
    }
}

/// 评论过滤器
pub struct ReviewFilter;

impl ReviewFilter {
    /// 从评论列表中筛选本章热评
    pub fn hot_reviews(reviews: &[ChapterReview]) -> Vec<&ChapterReview> {
        reviews.iter().filter(|r| r.is_chapter_hot_review()).collect()
    }

    /// 从评论列表中筛选指定段落的段评
    pub fn paragraph_reviews(reviews: &[ChapterReview], paragraph_index: i32) -> Vec<&ChapterReview> {
        reviews
            .iter()
            .filter(|r| r.paragraph_index == paragraph_index)
            .collect()
    }

    /// 按点赞数降序排列
    pub fn sort_by_likes(reviews: &mut [ChapterReview]) {
        reviews.sort_by(|a, b| b.like_count.cmp(&a.like_count));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_review(
        id: i64,
        book_url: &str,
        chapter_index: i32,
        paragraph_index: i32,
        like_count: i32,
    ) -> ChapterReview {
        ChapterReview {
            id,
            book_url: book_url.to_string(),
            chapter_index,
            paragraph_index,
            content: format!("Review {id}"),
            author: format!("user{id}"),
            created_at: 1000 + id,
            like_count,
        }
    }

    #[test]
    fn test_is_chapter_hot_review() {
        let review = make_review(1, "book1", 0, -1, 10);
        assert!(review.is_chapter_hot_review());
        assert!(!review.is_paragraph_review());
    }

    #[test]
    fn test_is_paragraph_review() {
        let review = make_review(1, "book1", 0, 3, 5);
        assert!(review.is_paragraph_review());
        assert!(!review.is_chapter_hot_review());
    }

    #[test]
    fn test_hot_reviews_filter() {
        let reviews = vec![
            make_review(1, "book1", 0, -1, 10),
            make_review(2, "book1", 0, 2, 5),
            make_review(3, "book1", 0, -1, 8),
            make_review(4, "book1", 0, 5, 3),
        ];
        let hot = ReviewFilter::hot_reviews(&reviews);
        assert_eq!(hot.len(), 2);
        assert!(hot.iter().all(|r| r.paragraph_index < 0));
    }

    #[test]
    fn test_paragraph_reviews_filter() {
        let reviews = vec![
            make_review(1, "book1", 0, 2, 10),
            make_review(2, "book1", 0, 3, 5),
            make_review(3, "book1", 0, 2, 8),
        ];
        let para2 = ReviewFilter::paragraph_reviews(&reviews, 2);
        assert_eq!(para2.len(), 2);
        assert!(para2.iter().all(|r| r.paragraph_index == 2));
    }

    #[test]
    fn test_sort_by_likes() {
        let mut reviews = vec![
            make_review(1, "book1", 0, -1, 3),
            make_review(2, "book1", 0, -1, 10),
            make_review(3, "book1", 0, -1, 7),
        ];
        ReviewFilter::sort_by_likes(&mut reviews);
        assert_eq!(reviews[0].like_count, 10);
        assert_eq!(reviews[1].like_count, 7);
        assert_eq!(reviews[2].like_count, 3);
    }

    #[test]
    fn test_hot_reviews_empty() {
        let reviews: Vec<ChapterReview> = vec![];
        let hot = ReviewFilter::hot_reviews(&reviews);
        assert!(hot.is_empty());
    }
}
