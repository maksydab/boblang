fn main() {
    println!("primes");
    let limit = 10_000_000usize;
    let mut sieve = vec![true; limit];
    sieve[0] = false;
    sieve[1] = false;
    let mut i = 2;
    while i * i < limit {
        if sieve[i] {
            let mut j = i * i;
            while j < limit {
                sieve[j] = false;
                j += i;
            }
        }
        i += 1;
    }
    let mut total: i64 = 0;
    let mut k = 2;
    while k < limit {
        if sieve[k] {
            total += k as i64;
        }
        k += 1;
    }
    println!("{}", total);
}
