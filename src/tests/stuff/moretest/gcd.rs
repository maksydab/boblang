fn main() {
    println!("gcd");
    let mut a: i64 = 123456789012;
    let mut b: i64 = 987654321098;
    while b != 0 { let t = b; b = a % b; a = t; }
    println!("{}", a);
}
