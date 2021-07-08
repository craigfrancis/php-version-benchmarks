#!/usr/bin/env bash
set -e

print_result_header () {
    printf "Benchmark\tMetric\tAverage\tMedian\tStdDev\tDescription\n" >> "$result_file_tsv"

cat << EOF >> "$result_file_md"
### $PHP_ID (opcache: $PHP_OPCACHE, preloading: $PHP_PRELOADING, JIT: $PHP_JIT)

|  Benchmark   |    Metric    |   Average   |   Median    |    StdDev   | Description |
|--------------|--------------|-------------|-------------|-------------|-------------|
EOF
}

print_result_value () {
    printf "%s\t%s\t%.5f\t%.5f\t%.5f\t%s\n" "$1" "$2" "$3" "$4" "$5" "$6" >> "$result_file_tsv"
    printf "|%s|%s|%.5f|%.5f|%.5f|%s|\n" "$1" "$2" "$3" "$4" "$5" "$6" >> "$result_file_md"
}

print_result_footer () {
    var="PHP_COMMITS_$PHP_ID"
    commit_hash="${!var}"
    url="${PHP_REPO//.git/}/commit/$commit_hash"
    now="$(date +'%Y-%m-%d %H:%M')"

    printf "\n##### Generated: $now based on commit [$commit_hash]($url)\n" >> "$result_file_md"
}

average () {
  echo "$1" | tr -s ' ' '\n' | awk '{sum+=$1}END{print sum/NR}'
}

median () {
  arr=($(printf '%f\n' "${@}" | sort -n))
  nel=${#arr[@]}
  if (( $nel % 2 == 1 )); then
    val="${arr[ $(($nel/2)) ]}"
  else
    (( j=nel/2 ))
    (( k=j-1 ))
    val=$(echo "scale=6;(${arr[j]}" + "${arr[k]})/2"|bc -l)
  fi
  echo $val
}

std_deviation () {
    echo "$1" | tr -s ' ' '\n' | awk '{sum+=$1; sumsq+=$1*$1}END{print sqrt(sumsq/NR - (sum/NR)**2)}'
}

run_cgi () {
    sleep 0.25

    if [[ "$INFRA_PROVISIONER" == "host" ]]; then
        if [ "$PHP_OPCACHE" = "1" ]; then
            opcache="-d zend_extension=$php_source_path/modules/opcache.so"
        else
            opcache=""
        fi

        export CONTENT_TYPE="text/html; charset=utf-8"
        export SCRIPT_FILENAME="$PROJECT_ROOT/$4"
        export REQUEST_URI="$5"
        export APP_ENV="$6"
        export APP_DEBUG=false
        export SESSION_DRIVER=cookie
        export LOG_LEVEL=warning

        if [ "$1" = "quiet" ]; then
            taskset 4 $php_source_path/sapi/cgi/php-cgi $opcache -T "$2,$3" "$PROJECT_ROOT/$4" > /dev/null
        else
            taskset 4 $php_source_path/sapi/cgi/php-cgi $opcache -q -T "$2,$3" "$PROJECT_ROOT/$4"
        fi
    elif [[ "$INFRA_PROVISIONER" == "docker" ]]; then
        if [[ "$INFRA_ENVIRONMENT" == "local" ]]; then
            run_as=""
            repository="$INFRA_DOCKER_REPOSITORY"
        elif [[ "$INFRA_ENVIRONMENT" == "aws" ]]; then
            run_as="sudo"
            repository="$INFRA_DOCKER_REGISTRY/$INFRA_DOCKER_REPOSITORY"
        fi

        $run_as docker run --rm --log-driver=none --env-file "$PHP_CONFIG_FILE" \
            --volume "$PROJECT_ROOT/build:/code/build:delegated" --volume "$PROJECT_ROOT/app:/code/app:delegated" \
            "$repository:$PHP_ID-latest" /code/build/container/php-cgi/run.sh "$1" "$2,$3" "$4" "$5" "$6"
    fi
}

run_real_benchmark () {
    echo "---------------------------------------------------------------------------------------"
    echo "Benchmarking $TEST_NAME: $PHP_NAME (opcache: $PHP_OPCACHE, preloading: $PHP_PRELOADING, JIT: $PHP_JIT)"
    echo "---------------------------------------------------------------------------------------"

    # Benchmark
    run_cgi "quiet" "$TEST_WARMUP" "$TEST_REQUESTS" "$1" "$2" "$3" > /dev/null 2>&1
    for b in $(seq $TEST_ITERATIONS); do
        run_cgi "quiet" "$TEST_WARMUP" "$TEST_REQUESTS" "$1" "$2" "$3" 2>&1 | tee -a "$log_path/${TEST_NUMBER}_$TEST_ID.log"
    done

    # Format log
    sed -i".original" "/^[[:space:]]*$/d" "$log_path/${TEST_NUMBER}_$TEST_ID.log"
    sed -i".original" "s/Elapsed time\: //g" "$log_path/${TEST_NUMBER}_$TEST_ID.log"
    sed -i".original" "s/ sec//g" "$log_path/${TEST_NUMBER}_$TEST_ID.log"
    rm "$log_path/${TEST_NUMBER}_$TEST_ID.log.original"

    # Collect results
    results="$(cat "$log_path/${TEST_NUMBER}_$TEST_ID.log")"
    print_result_value "$TEST_NAME" "time (sec)" "$(average $results)" "$(median $results)" "$(std_deviation "$results")" "$TEST_ITERATIONS consecutive runs, $TEST_REQUESTS requests"
}

run_micro_benchmark () {
    echo "---------------------------------------------------------------------------------------"
    echo "Benchmarking $TEST_NAME : $PHP_NAME (opcache: $PHP_OPCACHE, preloading: $PHP_PRELOADING, JIT: $PHP_JIT)"
    echo "---------------------------------------------------------------------------------------"

    # Benchmark
    run_cgi "quiet" "$TEST_WARMUP" "$TEST_ITERATIONS" "$1" "" "" > /dev/null 2>&1
    run_cgi "verbose" "$TEST_WARMUP" "$TEST_ITERATIONS" "$1" "" "" 2>&1 | tee -a "$log_path/${TEST_NUMBER}_$TEST_ID.log"

    # Format log
    results="$(grep "Total" "$log_path/${TEST_NUMBER}_$TEST_ID.log")"
    echo "$results" > "$log_path/${TEST_NUMBER}_$TEST_ID.log"
    sed -i".original" "s/Total              //g" "$log_path/${TEST_NUMBER}_$TEST_ID.log"
    rm "$log_path/${TEST_NUMBER}_$TEST_ID.log.original"

    # Calculate
    results="$(cat "$log_path/${TEST_NUMBER}_$TEST_ID.log")"
    print_result_value "$TEST_NAME" "time (sec)" "$(average $results)" "$(median $results)" "$(std_deviation "$results")" "$TEST_ITERATIONS consecutive runs"
}

run_test () {

    case "$TEST_ID" in

        laravel)
            run_real_benchmark "app/laravel/public/index.php" "" "production"
            ;;

        symfony_main)
            run_real_benchmark "app/symfony/public/index.php" "/" "prod"
            ;;

        symfony_blog)
            run_real_benchmark "app/symfony/public/index.php" "/en/blog/" "prod"
            ;;

        bench)
            run_micro_benchmark "app/zend/bench.php"
            ;;

        micro_bench)
            run_micro_benchmark "app/zend/micro_bench.php"
            ;;

        concat)
            run_micro_benchmark "app/zend/concat.php"
            ;;

        *)
            echo "Invalid test ID!"
            ;;
    esac

}

run_benchmark () {

    for PHP_CONFIG_FILE in $PROJECT_ROOT/config/php/*.ini; do
        source $PHP_CONFIG_FILE
        export PHP_CONFIG_FILE
        php_source_path="$PROJECT_ROOT/tmp/$PHP_ID"

        log_path="$result_path/${PHP_ID}_${INFRA_ARCHITECTURE}"
        result_file_tsv="$result_path/${PHP_ID}_${INFRA_ARCHITECTURE}.tsv"
        result_file_md="$result_path/${PHP_ID}_${INFRA_ARCHITECTURE}.md"

        mkdir -p "$log_path"

        touch "$result_file_tsv"
        touch "$result_file_md"

        echo "---------------------------------------------------------------------------------------"
        echo "$RUN/$N - $INFRA_NAME - $PHP_NAME (opcache: $PHP_OPCACHE, preloading: $PHP_PRELOADING, JIT: $PHP_JIT)"
        echo "---------------------------------------------------------------------------------------"

        if [ "$TEST_NUMBER" = "1" ]; then
            print_result_header
        fi

        run_test

        if [ "$TEST_NUMBER" = "$TEST_COUNT" ]; then
            print_result_footer
        fi
    done

}

result_path="$PROJECT_ROOT/result/$RESULT_ROOT_DIR/$RUN"

TEST_NUMBER=0
TEST_COUNT=$(ls 2>/dev/null -Ubad1 -- ./config/test/*.ini | wc -l)

for test_config in $PROJECT_ROOT/config/test/*.ini; do
    source $test_config
    ((TEST_NUMBER=TEST_NUMBER+1))

    sleep 3
    run_benchmark

done
