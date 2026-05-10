CXX = g++
CXXFLAGS = -O2 -std=c++17 -pthread
TARGET = bin/fzf
OBJ = obj/fzf.o
SRC = fzf.cpp

all: $(TARGET)

$(TARGET): $(OBJ)
	mkdir -p bin
	$(CXX) $(CXXFLAGS) $(OBJ) -o $(TARGET)

$(OBJ): $(SRC)
	mkdir -p obj
	$(CXX) $(CXXFLAGS) -c $(SRC) -o $(OBJ)

clean:
	rm -rf bin obj
