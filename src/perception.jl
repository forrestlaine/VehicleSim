function perception_f(x, delta_t)
    # update xk = [p1 p2 theta vel l w h]
    # - updated-p1 = p1 + delta_time *cos(theta)*v
    # - updated-p2 = p2 + delta_time*sin(theta)*v
    theta_k = x[3]
    vel_k = x[4]
    x + delta_t * [vel_k * cos(theta_k), vel_k * sin(theta_k), 0, 0, 0, 0, 0]
end

function perception_jac_fx(x, delta_t)
    theta = x[3]
    vel = x[4]

    [1 0 (-sin(theta)*vel*delta_t) (delta_t*cos(theta)) 0 0 0
        0 1 (cos(theta)*vel*delta_t) (delta_t*sin(theta)) 0 0 0
        0 0 1 0 0 0 0
        0 0 0 1 0 0 0
        0 0 0 0 1 0 0
        0 0 0 0 0 1 0
        0 0 0 0 0 0 1
    ]

end

function perception_get_3d_bbox_corners(state, box_size)
    # quat = state.q[1:4]
    # xyz = state.q[5:7]
    # T = get_body_transform(quat, xyz)
    corners = []
    for dx in [-box_size[1] / 2, box_size[1] / 2]
        for dy in [-box_size[2] / 2, box_size[2] / 2]
            for dz in [-box_size[3] / 2, box_size[3] / 2]
                push!(corners, T * [dx, dy, dz, 1])
            end
        end
    end
    corners
end


"""
    Parameters:
        - x_other: state of a recognized car (in [p1 p2 theta vel l w h])
        - x_ego: state of ego car (in a format that localization gives)

"""
function perception_h(x_other, x_ego)
    # constant variables
    vehicle_size = SVector(13.2, 5.7, 5.3)
    focal_len = 0.01
    pixel_len = 0.001
    image_width = 640
    image_height = 480
    num_vehicles = length(x_other)

    # PROBLEM: states of xs will not have the right states that the get_3d_bbox_corners() function requires
    corners_body = [perception_get_3d_bbox_corners(state, vehicle_size) for state in x_other] # currently, assuming that we have multiple cars in the camera(s) detected

    # Section 1: Get transformation matrices
    T_body_cam1 = get_cam_transform(1)
    T_body_cam2 = get_cam_transform(2)
    T_cam_camrot = get_rotated_camera_transform()

    T_body_camrot1 = multiply_transforms(T_body_cam1, T_cam_camrot)
    T_body_camrot2 = multiply_transforms(T_body_cam2, T_cam_camrot)

    # make sure the ego state you get from localization team follows the same format
    T_world_body = get_body_transform(x_ego.q[1:4], x_ego.q[5:7]) # get_body_transform(quat, loc)
    T_world_camrot1 = multiply_transforms(T_world_body, T_body_camrot1)
    T_world_camrot2 = multiply_transforms(T_world_body, T_body_camrot2)
    T_camrot1_world = invert_transform(T_world_camrot1)
    T_camrot2_world = invert_transform(T_world_camrot2)

    # Section 2: Calculate the bounding boxes
    # This is for both cam 1 and 2
    bboxes = []
    for transform in (T_camrot1_world, T_camrot2_world)
        for j = 1:num_vehicles
            # like x_carrot = R * [q1 q2 q3] + t to turn points rotated cam frame
            corners_of_other_vehicle = [transform * [pt; 1] for pt in corners_body[j]]

            left = image_width / 2
            right = -image_width / 2
            top = image_height / 2
            bot = -image_height / 2

            # we are basically getting through each corner values in camera frame and 
            # keep updating the left, top, bottom, right values!
            for corner in corners_of_other_vehicle
                # every point of corner in camera frame now
                if corner[3] < focal_len
                    break
                end
                px = focal_len * corner[1] / corner[3]
                py = focal_len * corner[2] / corner[3]
                left = min(left, px)
                right = max(right, px)
                top = min(top, py)
                bot = max(bot, py)
            end

            if top ≈ bot || left ≈ right || top > bot || left > right
                # out of frame
                continue
            else
                top = convert_to_pixel(image_height, pixel_len, top)
                bot = convert_to_pixel(image_height, pixel_len, bot)
                left = convert_to_pixel(image_width, pixel_len, left)
                top = convert_to_pixel(image_width, pixel_len, right)
                push!(bboxes, SVector(top, left, bot, right))
            end
        end
    end

    return bboxes
end

function perception_jac_hx(x, x_ego)


end


"""
    Variables:
        - x = state of the other car = [p1 p2 theta vel l w h] (7 x 1)
        - P = covariance of the state
        - z = measurement = [y1a y2a y1b y2b] (4 x 1)
        - Q = process noise
        - R = measurement noise
"""
function perception_ekf(z, xego, delta_t)
    # constant noise variables
    covariance_p = Diagonal([1^2, 1^2, 0.2^2, 0.4^2, 0.005^2, 0.003^2, 0.001^2])  # covariance for process model
    covariance_z = Diagonal([1^2, 1^2, 1^2, 1^2]) # covariance for measurement model
    # if length(z) > 4
    #     covariance_z = Diagonal([1^2, 1^2, 1^2, 1^2, 1^2, 1^2, 1^2, 1^2]) # we have 2 bounding boxes
    # end

    # initial states -- *change based on your state attributes
    x0 = [xego[1] + 2, xego[2] + 2, 0, xego[4], 8, 5, 5] # [p1 p2 theta vel l w h] -- later fix p1 and p2 by adding something to ego's position values
    mu = zeros(7) # mean value of xk state of the other car
    sigma = Diagonal([1^2, 1^2, 0.2^2, 0.4^2, 0.005^2, 0.003^2, 0.001^2])
    bb0 = [0 0 0 0]

    # variables to keep updating
    # timesteps = []
    # bbs = [bb0,]
    mus = [mu,] # the means
    sigmas = Matrix{Float64}[sigma,] # list of sigma_k's
    zs = Vector{Float64}[] # measurements of other car(s)

    x_prev = x0
    k = 1
    # *NOTE: currently at infinite loop!!!!!!
    while true # for k = 1:something
        xk = perception_f(x_prev, delta_t)
        x_prev = xk
        # NOTE: what if we have more than one bounding box?
        zk = perception_h(xk, x_egok) # measurement of bounding box (can be 4x1 or 8x1 depending on # of cameras recognizing car(s))

        # *All of the equations below are referenced from L17 pg.3 and HW4
        # Process model: P(xk | xk-1, bbxk) = N(A*x-1, sig_carrot))
        # - A = perception_jac_fx(x_prev, delta_t)
        # - sig_carrot = convariance_p + A * sigmas[k] * A'
        # - mu_carrot = perception_f(u[k], delta_t)
        A = perception_jac_fx(mus[k], delta_t)
        sig_carrot = covariance_p + A * sigmas[k] * A'
        mu_carrot = perception_f(mus[k], delta_t)

        # Measurement model
        # C = jac_hx(mu_carrot)
        C = perception_jac_hx(mu_carrot, xego)
        # NOTE: depending on the length of covariance_z, the size of C and others may have to be diff
        # - OR maybe just run it twice with cov_z being 4 elements long no matter what
        sigma_k = inv(inv(sig_carrot) + C' * inv(covariance_z) * C)
        mu_k = sigma_k * (inv(sigma_carrot) * mu_carrot + C' * inv(covariance_z) * zs[k])

        # update the variables
        push!(mus, mu_k)
        push!(sigmas, sigma_k)
        push!(zs, zk)
        # push!(gt_states, xk)
        # push!(timesteps, delta_t)

        k = k + 1
    end
end
