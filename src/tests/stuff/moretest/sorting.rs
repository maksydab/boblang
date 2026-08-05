fn main() {
    println!("sorting");
    let mut arr: [i32; 150] = [0; 150];
    for i in 0..150 { arr[i] = 150 - i as i32; }
    for i in 0..150 {
        for j in i+1..150 {
            if arr[j] < arr[i] { let t = arr[i]; arr[i] = arr[j]; arr[j] = t; }
        }
    }
    println!("{:?}", arr.to_vec());
}
