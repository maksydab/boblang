fn main() {
    println!("palindrome");
    let s = "amanaplanacanalpanama";
    let mut i = 0;
    let mut j = s.len() - 1;
    let mut is_pal = true;
    let bytes = s.as_bytes();
    while i < j { if bytes[i] != bytes[j] { is_pal = false; break; } i += 1; j -= 1; }
    println!("{}", if is_pal { "True" } else { "False" });
}
