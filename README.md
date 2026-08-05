# Boblang Compiler

A Python-like language that compiles to native binaries via LLVM.

## Usage

```
boblang <command> [file.bob] [options]
```

## Why Boblang?
- **Performance:** boblang is very fast compared to other dynamically typed languages, reaching rust levels of speed

- **Ease of use:** boblang was created with the user in mind, being very beginner friendly whilst also giving space to expand as your skillset grows by offering flexible interop with languages such as go and c

- **Customizability:** boblang will fit to your needs not your needs to boblang. No matter if you prefer python like syntax or more C like look, boblang got you covered with dialect system. It also comes with a package system that you fully control, no central repo just what you need hosted on any site or locally avaliable in one of your folders

note: the package management is fairly simple and a full on package manager is not yet fully implemented

## Example
### Hello world
```
print("Hello world")
```
### Number between 0-100 guesser
```
print("think of a number between 0 and 100")
print("i'll guess it, tho you need to tell me if im right or not")

low = 0
high = 100
guesses = 0

while True:
    guess = (low + high) // 2
    guesses = guesses + 1
    print("Is your number", guess, "?")

    answer = input("(h)igher, (l)ower, (c)orrect: ")

    if answer == "c":
        if guesses == 1:
            print("got it on the first try")
        else:
            print("got it in", guesses, "guesses")
        break
    elif answer == "h":
        low = guess + 1
    elif answer == "l":
        high = guess - 1
    else:
        print("please answer h, l, or c.")
        guesses = guesses - 1

    if low > high:
        print("you changed your number")
        break
```

## Docs
The proper documentation page is being worked on but in the meantime consult lg.md for immdiete answers

Release 0.0.1