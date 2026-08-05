fn main() {
    println!("collatz");
    let mut total: i64 = 0;
    for k in 1..=50000 {
        let mut n = k;
        let mut steps: i64 = 0;
        while n > 1 {
            if n % 2 == 0 { n /= 2; }
            else { n = 3 * n + 1; }
            steps += 1;
        }
        total += steps;
    }
    println!("{}", total);
}
