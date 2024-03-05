#!/bin/bash

requires_pattern="requires *(((\".*\")(,? *\n? *))*)"
file_path="libp2p.nimble"

get_dependencies_group() {
    dependencies=$(grep -Pzo "$requires_pattern" $1 | tr -d '\0')
    dependencies=$(sed 's/.*requires *//p' <<< "$dependencies")
    echo $dependencies
}

parse_group() {
    group=$(echo $1 | tr -d ' ' | tr -d '\n' | tr ',' ' ' | tr -d '\0')
    echo $group
}

clean_dependency() {
    dependency=$(echo $1 | tr -d '"')
    echo $dependency
}

dependencies_group=$(get_dependencies_group $file_path)
dependencies=$(parse_group "$dependencies_group")
var=()
for dependency in $dependencies; do
    var+=($(clean_dependency $dependency))
done

# print all elements in var
#
for i in "${var[@]}"; do
    echo "'"$i"'"
done
# echo "${var[@]}"
