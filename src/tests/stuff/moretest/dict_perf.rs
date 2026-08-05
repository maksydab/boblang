use std::collections::HashMap;
fn main() {
    println!("dict_perf");
    let mut d = HashMap::new();
    let mut s: i64 = 0;
    for i in 0..10000 { d.insert(i, i * 2); }
    for i in 0..10000 { s += d[&i]; }
    println!("{}", s);
}
