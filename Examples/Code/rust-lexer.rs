//! A tiny tokenizer for arithmetic expressions.
use std::fmt;
use std::iter::Peekable;
use std::str::Chars;

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Number(f64),
    Ident(String),
    Op(char),
    LParen,
    RParen,
}

#[derive(Debug)]
pub struct LexError {
    pub offset: usize,
    pub found: char,
}

impl fmt::Display for LexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unexpected {:?} at byte {}", self.found, self.offset)
    }
}

pub struct Lexer<'a> {
    chars: Peekable<Chars<'a>>,
    offset: usize,
}

impl<'a> Lexer<'a> {
    pub fn new(src: &'a str) -> Self {
        Lexer { chars: src.chars().peekable(), offset: 0 }
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.chars.next()?;
        self.offset += c.len_utf8();
        Some(c)
    }

    fn number(&mut self, first: char) -> Token {
        let mut s = String::from(first);
        while let Some(&c) = self.chars.peek() {
            if c.is_ascii_digit() || c == '.' { s.push(c); self.bump(); } else { break; }
        }
        Token::Number(s.parse().unwrap_or(0.0))
    }

    pub fn tokens(mut self) -> Result<Vec<Token>, LexError> {
        let mut out = Vec::new();
        while let Some(c) = self.bump() {
            match c {
                ' ' | '\t' | '\n' => continue,
                '0'..='9' => out.push(self.number(c)),
                'a'..='z' | 'A'..='Z' | '_' => out.push(Token::Ident(c.to_string())),
                '+' | '-' | '*' | '/' => out.push(Token::Op(c)),
                '(' => out.push(Token::LParen),
                ')' => out.push(Token::RParen),
                found => return Err(LexError { offset: self.offset, found }),
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_and_ops() {
        let t = Lexer::new("1 + 2.5 * (x - 3)").tokens().unwrap();
        assert_eq!(t.len(), 9);
        assert_eq!(t[0], Token::Number(1.0));
    }
}
