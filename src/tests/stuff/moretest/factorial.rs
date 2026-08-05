fn main() {
    println!("factorial");
    let mut n: i64 = 20;
    let mut r: i64 = 1;
    while n > 0 { r *= n; n -= 1; }
    println!("{}", r);
}
