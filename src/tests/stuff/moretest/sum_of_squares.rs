fn main() {
    println!("sum_of_squares");
    let mut n: i64 = 500000;
    let mut s: i64 = 0;
    while n > 0 { s += n * n; n -= 1; }
    println!("{}", s);
}
