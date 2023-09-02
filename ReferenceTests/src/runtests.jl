function get_frames(a, b)
    return (get_frames(a), get_frames(b))
end

conv_rgbf(x) = convert(Matrix{RGBf}, x)

function get_frames(video)
    mktempdir() do folder
        afolder = joinpath(folder, "a")
        mkpath(afolder)
        Makie.extract_frames(video, afolder)
        aframes = joinpath.(afolder, readdir(afolder))
        if length(aframes) > 10
            # we don't want to compare too many frames since it's time costly
            # so we just compare 10 random frames if more than 10
            samples = range(1, stop=length(aframes), length=10)
            istep = round(Int, length(aframes) / 10)
            samples = 1:istep:length(aframes)
            aframes = aframes[samples]
        end
        return conv_rgbf.(load.(aframes))
    end
end

function compare_media(a::Matrix{RGBf}, b::Matrix{RGBf})
    if size(a) != size(b)
        @warn "images don't have the same size, difference will be Inf"
        return Inf
    end
    Images.test_approx_eq_sigma_eps(a, b, sigma, Inf)
end

function compare_media(a, b)
    _, ext = splitext(a)
    if ext in (".png", ".jpg", ".jpeg", ".JPEG", ".JPG")
        imga = conv_rgbf(load(a))
        imgb = conv_rgbf(load(b))
        return compare_media(imga, imgb)
    elseif ext in (".mp4", ".gif")
        aframes, bframes = get_frames(a, b)
        # Frames can differ in length, which usually shouldn't be the case but can happen
        # when the implementation of record changes, or when the example changes its number of frames
        # In that case, we just return inf + warn
        if length(aframes) != length(bframes)
            @warn "not the same number of frames in video, difference will be Inf"
            return Inf
        end
        return maximum(compare_media.(aframes, bframes))
    else
        error("Unknown media extension: $ext")
    end
end

function get_all_relative_filepaths_recursively(dir)
    mapreduce(vcat, walkdir(dir)) do (root, dirs, files)
        relpath.(joinpath.(root, files), dir)
    end
end

function record_comparison(base_folder::String; record_folder_name="recorded", reference_name = basename(base_folder), tag=last_major_version())
    record_folder = joinpath(base_folder, record_folder_name)
    reference_folder = download_refimages(tag; name=reference_name)
    # we copy the reference images into the output folder, since we want to upload it all as an artifact, to know against what images we compared
    cp(reference_folder, joinpath(base_folder, "reference"))
    testimage_paths = get_all_relative_filepaths_recursively(record_folder)
    missing_refimages, scores = compare(testimage_paths, reference_folder, record_folder)

    open(joinpath(base_folder, "new_files.txt"), "w") do file
        for path in missing_refimages
            println(file, path)
        end
    end

    open(joinpath(base_folder, "scores.tsv"), "w") do file
        paths_scores = sort(collect(pairs(scores)), by = last, rev = true)
        for (path, score) in paths_scores
            println(file, score, '\t', path)
        end
    end

    return missing_refimages, scores
end

function test_comparison(scores; threshold)
    @testset "Comparison scores" begin
        for (image, score) in pairs(scores)
            @testset "$image" begin
                @test score <= threshold
            end
        end
    end
end

function compare(relative_test_paths::Vector{String}, reference_dir::String, record_dir; o_refdir=reference_dir, missing_refimages=String[], scores=Dict{String,Float64}())
    for relative_test_path in relative_test_paths
        ref_path = joinpath(reference_dir, relative_test_path)
        rec_path = joinpath(record_dir, relative_test_path)
        if !isfile(ref_path)
            push!(missing_refimages, relative_test_path)
        elseif endswith(ref_path, ".html")
            # ignore
        else
            diff = compare_media(rec_path, ref_path)
            scores[relative_test_path] = diff
        end
    end
    return missing_refimages, scores
end
